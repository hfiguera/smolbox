//! Streaming pack validation. This never extracts, mounts or calls the SDK.
//! Tar metadata is parsed before any variable allocation, including GNU/PAX
//! extensions and sparse maps that ordinary tar iterators consume internally.
use crate::{Error, ErrorCode, Resources, Result};
use smolvm_pack::format::PackManifest;
use std::collections::BTreeMap;
use std::io::{self, Read};

const MAX_ASSETS: usize = 256;
const MAX_PATH: usize = 4096;
const MAX_EXTENSION: u64 = 16 * 1024;
const MAX_ENTRIES: u64 = 200_000;
const MAX_BYTES: u64 = 128 * 1024 * 1024 * 1024;
const MAX_SPARSE: usize = 4096;

#[derive(Clone, Copy)]
enum AssetKind {
    Bytes,
    Tar,
    Disk(u64),
}

pub(crate) fn validate_assets(
    input: impl Read,
    manifest: &PackManifest,
    resources: Resources,
) -> Result<()> {
    validate(input, manifest, resources).map_err(|_| Error::before(ErrorCode::Validation))
}

fn validate(input: impl Read, manifest: &PackManifest, resources: Resources) -> io::Result<()> {
    if manifest.assets.agent_rootfs.path != "agent-rootfs.tar" {
        return invalid();
    }
    let mut expected = BTreeMap::new();
    let mut add = |path: &str, size, kind| {
        let path = normalized(path.as_bytes(), false)?;
        if path.is_empty()
            || size == 0
            || size > MAX_BYTES
            || expected.len() >= MAX_ASSETS
            || expected.insert(path, (size, kind)).is_some()
        {
            return invalid();
        }
        Ok(())
    };
    add(
        &manifest.assets.agent_rootfs.path,
        manifest.assets.agent_rootfs.size,
        AssetKind::Tar,
    )?;
    for library in &manifest.assets.libraries {
        add(&library.path, library.size, AssetKind::Bytes)?;
    }
    for layer in &manifest.assets.layers {
        // The SDK derives both layer identity and order from the filename.
        let digest = layer.digest.strip_prefix("sha256:").ok_or_else(bad)?;
        if !crate::domain::valid_hex(digest, 64) || layer.path != format!("layers/{digest}.tar") {
            return invalid();
        }
        add(&layer.path, layer.size, AssetKind::Tar)?;
    }
    if let Some(asset) = &manifest.assets.storage_template {
        add(
            &asset.path,
            asset.size,
            AssetKind::Disk(resources.storage_gib << 30),
        )?;
    }
    if let Some(asset) = &manifest.assets.overlay_template {
        add(
            &asset.path,
            asset.size,
            AssetKind::Disk(resources.overlay_gib << 30),
        )?;
    }
    let directory_paths: Vec<_> = expected.keys().cloned().collect();
    for (index, path) in directory_paths.iter().enumerate() {
        if directory_paths[index + 1..]
            .iter()
            .any(|child| child.starts_with(&[path.as_slice(), b"/"].concat()))
        {
            return invalid();
        }
    }
    let mut decoder = zstd::stream::read::Decoder::new(input)?;
    // An approved pack cannot request an arbitrarily large decompressor window.
    decoder.window_log_max(23)?;
    let mut decoded = Capped {
        input: decoder,
        remaining: MAX_BYTES,
    };
    let mut stats = Stats::default();
    walk(&mut decoded, &mut stats, &mut |entry, payload, stats| {
        if entry.kind == tar::EntryType::Directory {
            // The SDK collector creates these structural directories even for
            // a bare-VM pack with no OCI layers or inline runtime libraries.
            let structural = entry.path == b"layers" || entry.path == b"lib";
            if directory_paths.contains(&entry.path) {
                return invalid();
            }
            if !entry.path.is_empty()
                && !structural
                && !directory_paths
                    .iter()
                    .any(|path| path.starts_with(&[entry.path.as_slice(), b"/"].concat()))
            {
                return invalid();
            }
            return Ok(());
        }
        if !matches!(
            entry.kind,
            tar::EntryType::Regular | tar::EntryType::GNUSparse
        ) {
            return invalid();
        }
        let (size, kind) = expected.remove(&entry.path).ok_or_else(bad)?;
        if size != entry.size {
            return invalid();
        }
        match kind {
            AssetKind::Bytes => Ok(()),
            AssetKind::Tar => walk(payload, stats, &mut validate_guest_entry),
            AssetKind::Disk(cap) => validate_disk(payload, size, cap),
        }
    })?;
    if !expected.is_empty() {
        return invalid();
    }
    Ok(())
}

fn validate_guest_entry(
    entry: Entry,
    _payload: &mut dyn Read,
    _stats: &mut Stats,
) -> io::Result<()> {
    if entry.path.is_empty() && entry.kind != tar::EntryType::Directory {
        return invalid();
    }
    match entry.kind {
        tar::EntryType::Regular
        | tar::EntryType::GNUSparse
        | tar::EntryType::Continuous
        | tar::EntryType::Directory
        | tar::EntryType::Char
        | tar::EntryType::Block
        | tar::EntryType::Fifo => Ok(()),
        tar::EntryType::Symlink | tar::EntryType::Link => {
            let link = entry.link.ok_or_else(bad)?;
            if link.is_empty() {
                return invalid();
            }
            let absolute = link.starts_with(b"/");
            let base = if entry.kind == tar::EntryType::Symlink && !absolute {
                entry
                    .path
                    .rsplitn(2, |c| *c == b'/')
                    .nth(1)
                    .unwrap_or_default()
            } else {
                &[]
            };
            let target = normalized(&[base, b"/", &link].concat(), true)?;
            if absolute && target.is_empty() {
                return invalid();
            }
            Ok(())
        }
        _ => invalid(),
    }
}

pub(crate) fn validate_disk(input: &mut dyn Read, size: u64, cap: u64) -> io::Result<()> {
    if size < 2048 || size > cap {
        return invalid();
    }
    let mut prefix = [0u8; 2048];
    input.read_exact(&mut prefix)?;
    let sb = &prefix[1024..];
    if u16::from_le_bytes(sb[56..58].try_into().unwrap()) != 0xef53 {
        return invalid();
    }
    let low = u32::from_le_bytes(sb[4..8].try_into().unwrap()) as u64;
    let incompat = u32::from_le_bytes(sb[96..100].try_into().unwrap());
    let high = if incompat & 0x80 != 0 {
        u32::from_le_bytes(sb[336..340].try_into().unwrap()) as u64
    } else {
        0
    };
    let log = u32::from_le_bytes(sb[24..28].try_into().unwrap());
    let blocks = low | (high << 32);
    if log > 6 || blocks == 0 || blocks.checked_mul(1024u64 << log).is_none_or(|n| n > cap) {
        return invalid();
    }
    Ok(())
}

struct Entry {
    path: Vec<u8>,
    link: Option<Vec<u8>>,
    kind: tar::EntryType,
    size: u64,
}

#[derive(Default)]
struct Stats {
    entries: u64,
    bytes: u64,
}

#[derive(Default)]
struct Extensions {
    path: Option<Vec<u8>>,
    link: Option<Vec<u8>>,
    size: Option<u64>,
    count: u8,
}

fn walk(
    input: &mut dyn Read,
    stats: &mut Stats,
    visit: &mut dyn FnMut(Entry, &mut dyn Read, &mut Stats) -> io::Result<()>,
) -> io::Result<()> {
    let mut extensions = Extensions::default();
    loop {
        let mut block = [0u8; 512];
        input.read_exact(&mut block)?;
        if block == [0; 512] {
            if extensions.count != 0 {
                return invalid();
            }
            input.read_exact(&mut block)?;
            if block != [0; 512] {
                return invalid();
            }
            // Validate through the compression frame's end, not merely the tar
            // terminator. Hidden second archives and bad/truncated zstd tails fail.
            return drain_zero(input);
        }
        stats.entries += 1;
        if stats.entries > MAX_ENTRIES {
            return invalid();
        }
        let header = tar::Header::from_byte_slice(&block);
        let checksum: u32 = block
            .iter()
            .enumerate()
            .map(|(i, b)| {
                if (148..156).contains(&i) {
                    32
                } else {
                    *b as u32
                }
            })
            .sum();
        if header.cksum()? != checksum {
            return invalid();
        }
        let kind = header.entry_type();
        // entry_size is stored payload; size can be sparse logical size.
        let stored = header.entry_size()?;
        if kind.is_gnu_longname() || kind.is_gnu_longlink() || kind.is_pax_local_extensions() {
            extensions.count += 1;
            if extensions.count > 3 || stored > MAX_EXTENSION {
                return invalid();
            }
            let mut value = vec![0; stored as usize];
            input.read_exact(&mut value)?;
            if kind.is_pax_local_extensions() {
                pax(&value, &mut extensions)?;
            } else {
                if value.last() == Some(&0) {
                    value.pop();
                }
                if value.len() > MAX_PATH || value.contains(&0) {
                    return invalid();
                }
                let slot = if kind.is_gnu_longname() {
                    &mut extensions.path
                } else {
                    &mut extensions.link
                };
                if slot.replace(value).is_some() {
                    return invalid();
                }
            }
            padding(input, stored)?;
            continue;
        }
        // Global/path-changing PAX and GNU sparse PAX variants have no qualified
        // representation. Old-GNU sparse assets below are fully supported.
        if kind.is_pax_global_extensions() {
            return invalid();
        }
        let path = extensions
            .path
            .take()
            .unwrap_or_else(|| header.path_bytes().into_owned());
        let link = extensions
            .link
            .take()
            .or_else(|| header.link_name_bytes().map(|v| v.into_owned()));
        let stored = extensions.size.take().unwrap_or(stored);
        let mut size = stored;
        let mut extents = Vec::new();
        if kind.is_gnu_sparse() {
            let gnu = header.as_gnu().ok_or_else(bad)?;
            size = gnu.real_size()?;
            for slot in &gnu.sparse {
                add_extent(slot, &mut extents)?;
            }
            let mut extended = gnu.is_extended();
            let mut extension_blocks = 0;
            while extended {
                extension_blocks += 1;
                if extension_blocks > MAX_SPARSE.div_ceil(21) {
                    return invalid();
                }
                let mut more = tar::GnuExtSparseHeader::new();
                input.read_exact(more.as_mut_bytes())?;
                for slot in more.sparse() {
                    add_extent(slot, &mut extents)?;
                }
                extended = more.is_extended();
                if extents.len() >= MAX_SPARSE {
                    return invalid();
                }
            }
            let mut end = 0u64;
            let mut bytes = 0u64;
            for &(offset, length) in &extents {
                if offset < end || (length != 0 && !bytes.is_multiple_of(512)) {
                    return invalid();
                }
                end = offset.checked_add(length).ok_or_else(bad)?;
                bytes = bytes.checked_add(length).ok_or_else(bad)?;
            }
            if end != size || bytes != stored {
                return invalid();
            }
        }
        stats.bytes = stats.bytes.checked_add(size).ok_or_else(bad)?;
        if stats.bytes > MAX_BYTES {
            return invalid();
        }
        let entry = Entry {
            path: normalized(&path, false)?,
            link,
            kind,
            size,
        };
        if kind.is_gnu_sparse() {
            let mut sparse = Sparse {
                input,
                extents,
                index: 0,
                position: 0,
                size,
            };
            visit(entry, &mut sparse, stats)?;
            drain(&mut sparse)?;
        } else {
            let mut payload = input.take(stored);
            visit(entry, &mut payload, stats)?;
            drain(&mut payload)?;
            if payload.limit() != 0 {
                return invalid();
            }
        }
        padding(input, stored)?;
        extensions = Extensions::default();
    }
}

fn add_extent(slot: &tar::GnuSparseHeader, extents: &mut Vec<(u64, u64)>) -> io::Result<()> {
    if !slot.is_empty() {
        if extents.len() >= MAX_SPARSE {
            return invalid();
        }
        extents.push((slot.offset()?, slot.length()?));
    }
    Ok(())
}

fn pax(bytes: &[u8], extensions: &mut Extensions) -> io::Result<()> {
    let mut remaining = bytes;
    while !remaining.is_empty() {
        let space = remaining.iter().position(|b| *b == b' ').ok_or_else(bad)?;
        let length = decimal(&remaining[..space])?;
        let length = usize::try_from(length).map_err(|_| bad())?;
        if length <= space + 2 || length > remaining.len() || remaining[length - 1] != b'\n' {
            return invalid();
        }
        let data = &remaining[space + 1..length - 1];
        let equals = data.iter().position(|b| *b == b'=').ok_or_else(bad)?;
        let (key, value) = (&data[..equals], &data[equals + 1..]);
        match key {
            b"path" | b"linkpath" => {
                if value.len() > MAX_PATH || value.contains(&0) {
                    return invalid();
                }
                let slot = if key == b"path" {
                    &mut extensions.path
                } else {
                    &mut extensions.link
                };
                if slot.replace(value.to_vec()).is_some() {
                    return invalid();
                }
            }
            b"size" => {
                if extensions.size.replace(decimal(value)?).is_some() {
                    return invalid();
                }
            }
            key if key.starts_with(b"GNU.sparse.") => return invalid(),
            _ => {}
        }
        remaining = &remaining[length..];
    }
    Ok(())
}

fn decimal(bytes: &[u8]) -> io::Result<u64> {
    if bytes.is_empty() || bytes.len() > 20 {
        return invalid();
    }
    bytes.iter().try_fold(0u64, |n, b| {
        if !b.is_ascii_digit() {
            return invalid();
        }
        n.checked_mul(10)
            .and_then(|n| n.checked_add((b - b'0') as u64))
            .ok_or_else(bad)
    })
}

fn normalized(path: &[u8], absolute: bool) -> io::Result<Vec<u8>> {
    if path.len() > MAX_PATH || path.contains(&0) || (!absolute && path.starts_with(b"/")) {
        return invalid();
    }
    let mut components = Vec::new();
    for part in path.split(|c| *c == b'/') {
        match part {
            b"" | b"." => {}
            b".." => {
                if components.pop().is_none() {
                    return invalid();
                }
            }
            part => components.push(part),
        }
    }
    Ok(components.join(&b'/'))
}

struct Sparse<'a> {
    input: &'a mut dyn Read,
    extents: Vec<(u64, u64)>,
    index: usize,
    position: u64,
    size: u64,
}
impl Read for Sparse<'_> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if buffer.is_empty() || self.position == self.size {
            return Ok(0);
        }
        while self.index < self.extents.len()
            && self.position >= self.extents[self.index].0 + self.extents[self.index].1
        {
            self.index += 1;
        }
        let (offset, length) = self
            .extents
            .get(self.index)
            .copied()
            .unwrap_or((self.size, 0));
        let end = if self.position < offset {
            offset
        } else {
            offset + length
        };
        let count = (end - self.position).min(buffer.len() as u64) as usize;
        if self.position < offset {
            buffer[..count].fill(0);
        } else {
            self.input.read_exact(&mut buffer[..count])?;
        }
        self.position += count as u64;
        Ok(count)
    }
}

struct Capped<R> {
    input: R,
    remaining: u64,
}
impl<R: Read> Read for Capped<R> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        if self.remaining == 0 {
            let mut probe = [0; 1];
            return if self.input.read(&mut probe)? == 0 {
                Ok(0)
            } else {
                Err(bad())
            };
        }
        let length = self.remaining.min(buffer.len() as u64) as usize;
        let count = self.input.read(&mut buffer[..length])?;
        self.remaining -= count as u64;
        Ok(count)
    }
}

fn padding(input: &mut dyn Read, size: u64) -> io::Result<()> {
    let count = (512 - size % 512) % 512;
    let mut bytes = [0; 512];
    input.read_exact(&mut bytes[..count as usize])?;
    Ok(())
}
fn drain(input: &mut dyn Read) -> io::Result<()> {
    io::copy(input, &mut io::sink()).map(|_| ())
}
fn drain_zero(input: &mut dyn Read) -> io::Result<()> {
    let mut buffer = [0; 64 * 1024];
    loop {
        let count = input.read(&mut buffer)?;
        if count == 0 {
            return Ok(());
        }
        if buffer[..count].iter().any(|b| *b != 0) {
            return invalid();
        }
    }
}
fn bad() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid prepared pack")
}
fn invalid<T>() -> io::Result<T> {
    Err(bad())
}

#[cfg(test)]
mod tests {
    use super::*;
    use smolvm_pack::format::{AssetEntry, LayerEntry};

    fn tar(files: &[(&str, &[u8])]) -> Vec<u8> {
        let mut builder = tar::Builder::new(Vec::new());
        for (path, bytes) in files {
            let mut header = tar::Header::new_gnu();
            header.set_size(bytes.len() as u64);
            header.set_mode(0o644);
            header.set_cksum();
            builder.append_data(&mut header, path, *bytes).unwrap();
        }
        builder.into_inner().unwrap()
    }

    fn resources() -> Resources {
        Resources {
            cpus: 1,
            memory_mib: 512,
            storage_gib: 1,
            overlay_gib: 1,
        }
    }

    fn fixture() -> (PackManifest, Vec<u8>, String) {
        let guest = tar(&[("usr/bin/witness", b"payload")]);
        let digest = "a".repeat(64);
        let path = format!("layers/{digest}.tar");
        let mut manifest = PackManifest::new(
            "proof".into(),
            format!("sha256:{digest}"),
            "linux/arm64".into(),
            "proof".into(),
        );
        manifest.assets.agent_rootfs = AssetEntry {
            path: "agent-rootfs.tar".into(),
            size: guest.len() as u64,
        };
        manifest.assets.layers = vec![LayerEntry {
            digest: format!("sha256:{digest}"),
            path: path.clone(),
            size: guest.len() as u64,
        }];
        (manifest, guest, path)
    }

    fn qualified(manifest: &PackManifest, assets: &[u8]) -> Result<()> {
        let compressed = zstd::encode_all(assets, 1).unwrap();
        validate_assets(compressed.as_slice(), manifest, resources())
    }

    #[test]
    fn complete_asset_inventory_and_nested_archives_are_required() {
        let (mut manifest, guest, path) = fixture();
        let assets = tar(&[("agent-rootfs.tar", &guest), (&path, &guest)]);
        qualified(&manifest, &assets).unwrap();
        let missing = tar(&[("agent-rootfs.tar", &guest)]);
        assert!(qualified(&manifest, &missing).is_err());
        manifest.assets.layers[0].size += 1;
        assert!(qualified(&manifest, &assets).is_err());
        manifest.assets.layers[0].size -= 1;
        let duplicate = tar(&[
            ("agent-rootfs.tar", &guest),
            (&path, &guest),
            (&path, &guest),
        ]);
        assert!(qualified(&manifest, &duplicate).is_err());
        let extra = tar(&[
            ("agent-rootfs.tar", &guest),
            (&path, &guest),
            ("layers/hidden.tar", &guest),
        ]);
        assert!(qualified(&manifest, &extra).is_err());
        let garbage = vec![0x31; guest.len()];
        let invalid_tar = tar(&[("agent-rootfs.tar", &guest), (&path, &garbage)]);
        let error = qualified(&manifest, &invalid_tar).unwrap_err();
        assert_eq!(error.dispatch, crate::Dispatch::NotDispatched);
        assert_eq!(error.code, ErrorCode::Validation);
    }

    #[test]
    fn compression_and_tar_must_end_completely_without_hidden_payload() {
        let (manifest, guest, path) = fixture();
        let assets = tar(&[("agent-rootfs.tar", &guest), (&path, &guest)]);
        let mut compressed = zstd::encode_all(assets.as_slice(), 1).unwrap();
        compressed.pop();
        assert!(validate_assets(compressed.as_slice(), &manifest, resources()).is_err());
        let mut trailing = assets.clone();
        trailing.extend_from_slice(b"hidden payload");
        assert!(qualified(&manifest, &trailing).is_err());
        assert!(qualified(&manifest, &assets[..assets.len() - 512]).is_err());
    }

    #[test]
    fn extension_allocation_and_sparse_descriptor_work_are_bounded() {
        let mut exact = Capped {
            input: b"ok".as_slice(),
            remaining: 2,
        };
        let mut bytes = Vec::new();
        exact.read_to_end(&mut bytes).unwrap();
        assert_eq!(bytes, b"ok");
        let mut exceeded = Capped {
            input: b"no".as_slice(),
            remaining: 1,
        };
        assert!(exceeded.read_to_end(&mut Vec::new()).is_err());
        let mut header = tar::Header::new_gnu();
        header.set_entry_type(tar::EntryType::GNULongName);
        header.set_size(MAX_EXTENSION + 1);
        header.set_cksum();
        assert!(walk(
            &mut header.as_bytes().as_slice(),
            &mut Stats::default(),
            &mut validate_guest_entry
        )
        .is_err());
        let mut header = tar::Header::new_gnu();
        header.set_entry_type(tar::EntryType::GNUSparse);
        header.set_size(0);
        header.as_gnu_mut().unwrap().set_is_extended(true);
        header.set_cksum();
        let mut bytes = header.as_bytes().to_vec();
        let mut extension = tar::GnuExtSparseHeader::new();
        extension.set_is_extended(true);
        for _ in 0..=MAX_SPARSE.div_ceil(21) {
            bytes.extend_from_slice(extension.as_bytes());
        }
        assert!(walk(
            &mut bytes.as_slice(),
            &mut Stats::default(),
            &mut validate_guest_entry
        )
        .is_err());
    }

    #[test]
    fn bounded_gnu_and_pax_metadata_use_effective_paths() {
        let path = format!("dir/{}", "x".repeat(120));
        let valid = tar(&[(&path, b"payload")]);
        walk(
            &mut valid.as_slice(),
            &mut Stats::default(),
            &mut validate_guest_entry,
        )
        .unwrap();
        let mut extensions = Extensions::default();
        pax(b"19 path=../escape\n", &mut extensions).unwrap_err();
        // Valid PAX lengths are checked, then the effective path is checked by
        // the walker; syntax alone never makes a traversal path admissible.
        let record = b"18 path=../escape\n";
        assert_eq!(record.len(), 18);
        pax(record, &mut extensions).unwrap();
        assert!(normalized(extensions.path.as_ref().unwrap(), false).is_err());
    }

    #[test]
    fn asset_parent_collisions_and_guest_link_escapes_are_rejected() {
        let (mut manifest, guest, path) = fixture();
        manifest.assets.libraries.push(AssetEntry {
            path: "layers".into(),
            size: 1,
        });
        let assets = tar(&[
            ("agent-rootfs.tar", &guest),
            ("layers", b"x"),
            (&path, &guest),
        ]);
        assert!(qualified(&manifest, &assets).is_err());
        for target in ["../../../outside", "/", "/../outside"] {
            let entry = Entry {
                path: b"usr/link".to_vec(),
                link: Some(target.as_bytes().to_vec()),
                kind: tar::EntryType::Symlink,
                size: 0,
            };
            assert!(validate_guest_entry(entry, &mut io::empty(), &mut Stats::default()).is_err());
        }
        for target in ["../bin/witness", "/usr/bin/witness"] {
            let entry = Entry {
                path: b"usr/link".to_vec(),
                link: Some(target.as_bytes().to_vec()),
                kind: tar::EntryType::Symlink,
                size: 0,
            };
            validate_guest_entry(entry, &mut io::empty(), &mut Stats::default()).unwrap();
        }
    }

    fn superblock(blocks: u64) -> Vec<u8> {
        let mut disk = vec![0; 4096];
        let sb = &mut disk[1024..];
        sb[4..8].copy_from_slice(&(blocks as u32).to_le_bytes());
        sb[24..28].copy_from_slice(&2u32.to_le_bytes());
        sb[56..58].copy_from_slice(&0xef53u16.to_le_bytes());
        sb[96..100].copy_from_slice(&0x80u32.to_le_bytes());
        sb[336..340].copy_from_slice(&((blocks >> 32) as u32).to_le_bytes());
        disk
    }

    #[test]
    fn actual_ext4_geometry_cannot_exceed_admitted_backing_disks() {
        let disk = superblock((1 << 30) / 4096);
        validate_disk(&mut disk.as_slice(), disk.len() as u64, 1 << 30).unwrap();
        let larger = superblock((2 << 30) / 4096);
        assert!(validate_disk(&mut larger.as_slice(), larger.len() as u64, 1 << 30).is_err());
        let high = superblock(1 << 32);
        assert!(validate_disk(&mut high.as_slice(), high.len() as u64, 1 << 30).is_err());
        assert!(validate_disk(&mut [0u8; 2048].as_slice(), 2048, 1 << 30).is_err());
        assert!(validate_disk(&mut disk.as_slice(), (1 << 30) + 1, 1 << 30).is_err());
    }

    #[test]
    fn bare_vm_collector_empty_structural_directories_are_valid() {
        let (mut manifest, guest, _) = fixture();
        manifest.assets.layers.clear();
        let disk = superblock((1 << 30) / 4096);
        manifest.assets.overlay_template = Some(AssetEntry {
            path: "overlay.raw".into(),
            size: disk.len() as u64,
        });
        manifest.assets.storage_template = Some(AssetEntry {
            path: "storage.ext4".into(),
            size: disk.len() as u64,
        });
        let mut builder = tar::Builder::new(Vec::new());
        for path in ["layers", "lib"] {
            let mut header = tar::Header::new_gnu();
            header.set_entry_type(tar::EntryType::Directory);
            header.set_mode(0o755);
            header.set_size(0);
            header.set_cksum();
            builder.append_data(&mut header, path, io::empty()).unwrap();
        }
        for (path, data) in [
            ("agent-rootfs.tar", &guest),
            ("overlay.raw", &disk),
            ("storage.ext4", &disk),
        ] {
            let mut header = tar::Header::new_gnu();
            header.set_mode(0o600);
            header.set_size(data.len() as u64);
            header.set_cksum();
            builder
                .append_data(&mut header, path, data.as_slice())
                .unwrap();
        }
        qualified(&manifest, &builder.into_inner().unwrap()).unwrap();
    }

    #[test]
    fn old_gnu_sparse_disks_validate_logical_superblock_without_extraction() {
        let mut header = tar::Header::new_gnu();
        header.set_path("disk.raw").unwrap();
        header.set_size(1024);
        header.set_entry_type(tar::EntryType::GNUSparse);
        let gnu = header.as_gnu_mut().unwrap();
        gnu.set_real_size(4096);
        gnu.sparse[0].set_offset(1024);
        gnu.sparse[0].set_length(1024);
        gnu.sparse[1].set_offset(4096);
        gnu.sparse[1].set_length(0);
        header.set_cksum();
        let disk = superblock((1 << 30) / 4096);
        let mut bytes = header.as_bytes().to_vec();
        bytes.extend_from_slice(&disk[1024..2048]);
        bytes.extend_from_slice(&[0; 1024]);
        let mut observed = false;
        walk(
            &mut bytes.as_slice(),
            &mut Stats::default(),
            &mut |entry, payload, _| {
                observed = true;
                assert_eq!(entry.size, 4096);
                validate_disk(payload, entry.size, 1 << 30)
            },
        )
        .unwrap();
        assert!(observed);
        // This is the same sparse representation the SDK tar reader consumes.
        let mut archive = tar::Archive::new(bytes.as_slice());
        let mut entry = archive.entries().unwrap().next().unwrap().unwrap();
        let mut reconstructed = Vec::new();
        entry.read_to_end(&mut reconstructed).unwrap();
        assert_eq!(reconstructed, disk);
    }
}

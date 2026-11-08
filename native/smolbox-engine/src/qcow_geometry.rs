//! Bounded QCOW allocation-table and reference-count witness. Backing paths and
//! virtual filesystem evidence are verified by disk_geometry.
use crate::{Error, ErrorCode, ReadBudget, Result};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::File;
use std::os::unix::fs::FileExt;

pub(crate) const IO_BYTES: u64 = 64 * 1024 * 1024;
const TABLES: usize = 4096;
const BLOCK: usize = 4096;
// Bounded extent maps, pointer vectors, scan buffer and a capped dense u16
// reference map. Separate from the worker/watch/collector stack allowance.
const COUNT_BYTES: u64 = 8 * 1024 * 1024;
pub(crate) const MEMORY_BYTES: u64 = 1024 * 1024 + COUNT_BYTES;
const OFFSET: u64 = 0x00ff_ffff_ffff_fe00;
const COPIED: u64 = 1 << 63;

pub(crate) fn snapshot(
    file: &File,
    header: &[u8],
    budget: &ReadBudget,
    remaining: &mut u64,
) -> Result<[u8; 32]> {
    let cluster = 1u64 << u32::from_be_bytes(header[20..24].try_into().unwrap());
    let version = u32::from_be_bytes(header[4..8].try_into().unwrap());
    let l1_entries = u32::from_be_bytes(header[36..40].try_into().unwrap()) as u64;
    let l1 = be(&header[40..48]);
    let refcounts = be(&header[48..56]);
    let ref_clusters = u32::from_be_bytes(header[56..60].try_into().unwrap()) as u64;
    if l1_entries == 0 || l1_entries > (32 * 1024 * 1024 / 8) || ref_clusters == 0 {
        return invalid();
    }
    let mut scan = Scan {
        file,
        budget,
        length: file
            .metadata()
            .map_err(|_| Error::before(ErrorCode::Io))?
            .len(),
        cluster,
        remaining,
        areas: BTreeMap::new(),
        hash: Sha256::new(),
    };
    scan.area(0, cluster)?;
    let l1_bytes = l1_entries * 8;
    let l1_span = l1_bytes.div_ceil(cluster) * cluster;
    scan.area(l1, l1_span)?;
    let ref_bytes = ref_clusters
        .checked_mul(cluster)
        .filter(|n| *n <= 8 * 1024 * 1024)
        .ok_or(Error::before(ErrorCode::Validation))?;
    scan.area(refcounts, ref_bytes)?;
    scan.table(0, cluster, 0, |_, _| Ok(()))?;
    let mut l2 = Vec::new();
    scan.table(l1, l1_span, l1_entries, |entry, _| {
        if entry & !(OFFSET | COPIED) != 0 || (entry & OFFSET == 0 && entry != 0) {
            return invalid();
        }
        push(&mut l2, entry & OFFSET)
    })?;
    let mut blocks = Vec::new();
    scan.table(refcounts, ref_bytes, ref_bytes / 8, |entry, index| {
        if entry != 0 {
            if blocks.len() >= TABLES {
                return Err(Error::before(ErrorCode::Admission));
            }
            blocks.push((index, entry));
        }
        Ok(())
    })?;
    for offset in l2
        .iter()
        .copied()
        .chain(blocks.iter().map(|(_, offset)| *offset))
    {
        scan.area(offset, cluster)?;
    }
    let count = scan.length.div_ceil(cluster);
    if count > COUNT_BYTES / 2 {
        return Err(Error::before(ErrorCode::Admission));
    }
    let mut expected = Vec::<u16>::new();
    expected
        .try_reserve_exact(count as usize)
        .map_err(|_| Error::before(ErrorCode::Admission))?;
    expected.resize(count as usize, 0);
    for (start, end) in &scan.areas {
        for index in start / cluster..end / cluster {
            expected[index as usize] = 1;
        }
    }
    let areas = scan.areas.clone();
    for offset in &l2 {
        let length = scan.length;
        scan.table(*offset, cluster, cluster / 8, |entry, _| {
            if entry & (1 << 62) != 0 {
                return Err(Error::before(ErrorCode::Unsupported));
            }
            let allowed = OFFSET | COPIED | u64::from(version == 3);
            let offset = entry & OFFSET;
            if entry & !allowed != 0 || (entry & COPIED != 0 && offset == 0) {
                return invalid();
            }
            if offset != 0 {
                let end = extent(offset, cluster, cluster, length)?;
                if overlaps(&areas, offset, end) {
                    return invalid();
                }
                let count = &mut expected[(offset / cluster) as usize];
                *count = count
                    .checked_add(1)
                    .ok_or(Error::before(ErrorCode::Validation))?;
            }
            Ok(())
        })?;
    }
    // Counts are now complete, including shared data clusters. A copied flag
    // may assert exclusivity only when the actual reference count is one.
    for offset in l2 {
        scan.table(offset, cluster, cluster / 8, |entry, _| {
            if entry & COPIED != 0
                && expected.get(((entry & OFFSET) / cluster) as usize) != Some(&1)
            {
                return invalid();
            }
            Ok(())
        })?;
    }
    for (table_index, offset) in blocks {
        scan.table(offset, cluster, cluster / 8, |word, index| {
            for part in 0..4 {
                let actual = ((word >> (48 - 16 * part)) & 0xffff) as u16;
                let index = table_index * (cluster / 2) + index * 4 + part;
                match expected.get_mut(index as usize) {
                    Some(value) if *value == actual => *value = 0,
                    None if actual == 0 => {}
                    _ => return invalid(),
                }
            }
            Ok(())
        })?;
    }
    if expected.iter().any(|value| *value != 0) {
        return invalid();
    }
    budget.check()?;
    Ok(scan.hash.finalize().into())
}

/// Fill unresolved virtual superblock bytes. Unallocated clusters preserve the
/// mask for the next backing layer; explicit zero clusters suppress fallback.
pub(crate) fn superblock(
    file: &File,
    budget: &ReadBudget,
    bytes: &mut [u8; 1024],
    resolved: &mut [bool; 1024],
) -> Result<()> {
    logical_layer(file, budget, 1024, bytes, resolved)
}

/// Apply only mapped bytes from one already-qualified QCOW layer. Unmapped
/// bytes remain unresolved for the authenticated backing chain.
pub(crate) fn logical_layer(
    file: &File,
    budget: &ReadBudget,
    start: u64,
    bytes: &mut [u8],
    resolved: &mut [bool],
) -> Result<()> {
    if bytes.len() != resolved.len()
        || bytes.len() > 256 * 1024
        || start.checked_add(bytes.len() as u64).is_none()
    {
        return Err(Error::before(ErrorCode::Validation));
    }
    budget.check()?;
    let mut header = [0; 72];
    file.read_exact_at(&mut header, 0)
        .map_err(|_| Error::before(ErrorCode::Validation))?;
    let bits = u32::from_be_bytes(header[20..24].try_into().unwrap());
    let version = u32::from_be_bytes(header[4..8].try_into().unwrap());
    if header[..4] != *b"QFI\xfb" || !matches!(version, 2 | 3) || !(9..=21).contains(&bits) {
        return invalid();
    }
    let cluster = 1u64 << bits;
    let l1_size = u32::from_be_bytes(header[36..40].try_into().unwrap()) as u64;
    let l1 = be(&header[40..48]);
    let mut done = 0usize;
    while done < bytes.len() {
        budget.check()?;
        let virtual_offset = start + done as u64;
        let within = virtual_offset % cluster;
        let take = (cluster - within).min((bytes.len() - done) as u64) as usize;
        let l1_index = virtual_offset / cluster / (cluster / 8);
        let mut entry = 0;
        if l1_index < l1_size {
            let mut pointer = [0; 8];
            let position = l1
                .checked_add(l1_index * 8)
                .ok_or(Error::before(ErrorCode::Validation))?;
            file.read_exact_at(&mut pointer, position)
                .map_err(|_| Error::before(ErrorCode::Validation))?;
            if be(&pointer) & !(OFFSET | COPIED) != 0 {
                return invalid();
            }
            let l2 = be(&pointer) & OFFSET;
            if !l2.is_multiple_of(cluster) || (l2 == 0 && be(&pointer) != 0) {
                return invalid();
            }
            if l2 != 0 {
                let l2_index = virtual_offset / cluster % (cluster / 8);
                file.read_exact_at(&mut pointer, l2 + l2_index * 8)
                    .map_err(|_| Error::before(ErrorCode::Validation))?;
                entry = be(&pointer);
                if entry & (1 << 62) != 0 {
                    return Err(Error::before(ErrorCode::Unsupported));
                }
                let allowed = OFFSET | COPIED | u64::from(version == 3);
                if entry & !allowed != 0
                    || !(entry & OFFSET).is_multiple_of(cluster)
                    || (entry & COPIED != 0 && entry & OFFSET == 0)
                {
                    return invalid();
                }
            }
        }
        if entry & 1 != 0 || entry & OFFSET != 0 {
            let mut data = vec![0; take];
            if entry & 1 == 0 {
                file.read_exact_at(&mut data[..take], (entry & OFFSET) + within)
                    .map_err(|_| Error::before(ErrorCode::Validation))?;
            }
            for index in 0..take {
                if !resolved[done + index] {
                    bytes[done + index] = data[index];
                    resolved[done + index] = true;
                }
            }
        }
        done += take;
    }
    Ok(())
}

fn push(offsets: &mut Vec<u64>, offset: u64) -> Result<()> {
    if offset != 0 {
        if offsets.len() >= TABLES {
            return Err(Error::before(ErrorCode::Admission));
        }
        offsets.push(offset);
    }
    Ok(())
}

struct Scan<'a> {
    file: &'a File,
    budget: &'a ReadBudget,
    length: u64,
    cluster: u64,
    remaining: &'a mut u64,
    areas: BTreeMap<u64, u64>,
    hash: Sha256,
}
impl Scan<'_> {
    fn area(&mut self, offset: u64, bytes: u64) -> Result<()> {
        let end = extent(offset, bytes, self.cluster, self.length)?;
        if self.areas.len() >= TABLES || overlaps(&self.areas, offset, end) {
            return invalid();
        }
        self.areas.insert(offset, end);
        Ok(())
    }

    fn table(
        &mut self,
        offset: u64,
        bytes: u64,
        entries: u64,
        mut visit: impl FnMut(u64, u64) -> Result<()>,
    ) -> Result<()> {
        *self.remaining = self
            .remaining
            .checked_sub(bytes)
            .ok_or(Error::before(ErrorCode::Admission))?;
        self.hash.update(offset.to_be_bytes());
        self.hash.update(bytes.to_be_bytes());
        let mut buffer = [0; BLOCK];
        let mut done = 0;
        while done < bytes {
            self.budget.check()?;
            let take = (bytes - done).min(BLOCK as u64) as usize;
            self.file
                .read_exact_at(&mut buffer[..take], offset + done)
                .map_err(|_| Error::before(ErrorCode::Validation))?;
            if offset == 0 && done == 0 {
                // The clean SDK changes exactly this field during growth.
                buffer[24..32].fill(0);
            }
            self.hash.update(&buffer[..take]);
            for (index, value) in buffer[..take].as_chunks::<8>().0.iter().enumerate() {
                let entry = done / 8 + index as u64;
                if entry < entries {
                    visit(be(value), entry)?;
                }
            }
            done += take as u64;
        }
        Ok(())
    }
}

fn be(bytes: &[u8]) -> u64 {
    u64::from_be_bytes(bytes.try_into().unwrap())
}
fn extent(offset: u64, bytes: u64, cluster: u64, length: u64) -> Result<u64> {
    offset
        .checked_add(bytes)
        .filter(|end| bytes != 0 && offset.is_multiple_of(cluster) && *end <= length)
        .ok_or(Error::before(ErrorCode::Validation))
}
fn overlaps(areas: &BTreeMap<u64, u64>, start: u64, end: u64) -> bool {
    areas
        .range(..end)
        .next_back()
        .is_some_and(|(_, old_end)| *old_end > start)
}
fn invalid<T>() -> Result<T> {
    Err(Error::before(ErrorCode::Validation))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Cancellation;

    #[test]
    fn allocation_io_budget_is_shared_and_failed_scans_cannot_restore_it() {
        let temporary = tempfile::tempdir().unwrap();
        let path = crate::disk_geometry::tests::qcow(temporary.path(), 3);
        let file = File::open(path).unwrap();
        let mut header = [0; 104];
        file.read_exact_at(&mut header, 0).unwrap();
        let budget =
            ReadBudget::new(std::time::Duration::from_secs(1), Cancellation::new()).unwrap();
        let mut remaining = 464 * 1024;
        snapshot(&file, &header, &budget, &mut remaining).unwrap();
        assert_eq!(remaining, 80 * 1024);
        assert_eq!(
            snapshot(&file, &header, &budget, &mut remaining)
                .err()
                .unwrap()
                .code,
            ErrorCode::Admission
        );
        assert_eq!(remaining, 16 * 1024);
        assert!(snapshot(&file, &header, &budget, &mut remaining).is_err());
        assert_eq!(remaining, 16 * 1024);
    }

    #[test]
    fn virtual_superblock_splits_clusters_and_distinguishes_unallocated_from_explicit_zero() {
        // A mapping-only fragment, not a fully validated QCOW image or VM.
        let file = tempfile::tempfile().unwrap();
        file.set_len(2560).unwrap();
        let mut header = [0; 72];
        header[..4].copy_from_slice(b"QFI\xfb");
        header[4..8].copy_from_slice(&3u32.to_be_bytes());
        header[20..24].copy_from_slice(&9u32.to_be_bytes());
        header[36..40].copy_from_slice(&1u32.to_be_bytes());
        header[40..48].copy_from_slice(&512u64.to_be_bytes());
        file.write_all_at(&header, 0).unwrap();
        file.write_all_at(&(COPIED | 1024).to_be_bytes(), 512)
            .unwrap();
        file.write_all_at(&(COPIED | 1536).to_be_bytes(), 1024 + 2 * 8)
            .unwrap();
        file.write_all_at(&(COPIED | 2048).to_be_bytes(), 1024 + 3 * 8)
            .unwrap();
        file.write_all_at(&[7; 512], 1536).unwrap();
        file.write_all_at(&[9; 512], 2048).unwrap();
        let budget =
            ReadBudget::new(std::time::Duration::from_secs(1), Cancellation::new()).unwrap();
        let mut bytes = [0; 1024];
        let mut resolved = [false; 1024];
        superblock(&file, &budget, &mut bytes, &mut resolved).unwrap();
        assert_eq!(bytes[..512], [7; 512]);
        assert_eq!(bytes[512..], [9; 512]);
        assert!(resolved.iter().all(|value| *value));

        file.write_all_at(&1u64.to_be_bytes(), 1024 + 2 * 8)
            .unwrap();
        file.write_all_at(&0u64.to_be_bytes(), 1024 + 3 * 8)
            .unwrap();
        let mut bytes = [8; 1024];
        let mut resolved = [false; 1024];
        superblock(&file, &budget, &mut bytes, &mut resolved).unwrap();
        assert_eq!(bytes[..512], [0; 512]);
        assert_eq!(bytes[512..], [8; 512]);
        assert!(resolved[..512].iter().all(|value| *value));
        assert!(resolved[512..].iter().all(|value| !*value));

        file.write_all_at(&64u32.to_be_bytes(), 20).unwrap();
        assert!(superblock(&file, &budget, &mut bytes, &mut resolved).is_err());
        let cancel = Cancellation::new();
        cancel.cancel();
        let budget = ReadBudget::new(std::time::Duration::from_secs(1), cancel).unwrap();
        assert_eq!(
            superblock(&file, &budget, &mut bytes, &mut resolved)
                .err()
                .unwrap()
                .code,
            ErrorCode::State
        );
    }
}

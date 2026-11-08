//! Private immutable paths captured from the verified original SDK manager.
//! Historical identity checks must survive SDK namespace removal. They grant
//! neither live collection nor deletion, and cannot reconstruct a manager.
use crate::{Error, ErrorCode, Result};
use std::path::{Path, PathBuf};

pub(crate) struct ManagerPaths {
    child: crate::branch_boot::Directory,
    storage: PathBuf,
    overlay: PathBuf,
}
impl ManagerPaths {
    pub(crate) fn capture(
        plan: &crate::branch_boot::Plan,
        manager: &smolvm::agent::AgentManager,
    ) -> Result<Self> {
        Self::capture_paths(
            plan,
            manager.name(),
            manager.storage_path(),
            manager.overlay_path(),
        )
    }
    fn capture_paths(
        plan: &crate::branch_boot::Plan,
        name: Option<&str>,
        storage: &Path,
        overlay: &Path,
    ) -> Result<Self> {
        super::collection::verify_manager_disks(plan, name, storage, overlay)?;
        Ok(Self {
            child: plan.child.clone(),
            storage: storage.into(),
            overlay: overlay.into(),
        })
    }
    pub(crate) fn verify(
        &self,
        plan: &crate::branch_boot::Plan,
        manager: &smolvm::agent::AgentManager,
    ) -> Result<()> {
        self.matches_paths(
            plan,
            manager.name(),
            manager.storage_path(),
            manager.overlay_path(),
        )
    }
    pub(crate) fn verify_collected(
        &self,
        plan: &crate::branch_boot::Plan,
        manager: &smolvm::agent::AgentManager,
    ) -> Result<()> {
        self.matches_collected_paths(
            plan,
            manager.name(),
            manager.child_pid(),
            manager.storage_path(),
            manager.overlay_path(),
        )
    }
    fn matches_collected_paths(
        &self,
        plan: &crate::branch_boot::Plan,
        name: Option<&str>,
        pid: Option<i32>,
        storage: &Path,
        overlay: &Path,
    ) -> Result<()> {
        if pid.is_some() {
            return Err(Error::before(ErrorCode::Ownership));
        }
        self.matches_paths(plan, name, storage, overlay)
    }
    fn matches_paths(
        &self,
        plan: &crate::branch_boot::Plan,
        name: Option<&str>,
        storage: &Path,
        overlay: &Path,
    ) -> Result<()> {
        plan.validate()?;
        if self.child != plan.child
            || name != Some(plan.publication.child().name.as_str())
            || self.storage != storage
            || self.overlay != overlay
        {
            return Err(Error::before(ErrorCode::Ownership));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::branch_boot::tests::identity_model;
    use std::io::Write;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    fn disk(path: &Path) {
        // Private pathname facts only; these are not valid disk images. No SDK
        // manager, VMM, runtime cached handle or process collection is created.
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(path)
            .unwrap()
            .write_all(b"private path facts")
            .unwrap();
    }
    #[test]
    fn original_paths_bind_actual_raw_and_qcow_selection_and_reject_crossed_identity() {
        for se in ["raw", "qcow2"] {
            for oe in ["raw", "qcow2"] {
                let model = identity_model(true);
                let storage = model.plan.child.path.join(format!("storage.{se}"));
                let overlay = model.plan.child.path.join(format!("overlay.{oe}"));
                disk(&storage);
                disk(&overlay);
                let name = Some(model.record.name.as_str());
                let paths =
                    ManagerPaths::capture_paths(&model.plan, name, &storage, &overlay).unwrap();
                paths
                    .matches_paths(&model.plan, name, &storage, &overlay)
                    .unwrap();
                assert!(paths
                    .matches_paths(&model.plan, None, &storage, &overlay)
                    .is_err());
                assert!(paths
                    .matches_paths(&model.plan, Some("other"), &storage, &overlay)
                    .is_err());
                assert!(paths
                    .matches_paths(&model.plan, name, &overlay, &storage)
                    .is_err());
                let mut changed = model.plan.clone();
                changed.child.inode += 1;
                assert!(paths
                    .matches_paths(&changed, name, &storage, &overlay)
                    .is_err());
            }
        }
    }
    #[test]
    fn collected_original_boot_keeps_raw_or_qcow_locators_and_rejects_a_live_manager() {
        for ext in ["raw", "qcow2"] {
            let model = identity_model(true);
            let storage = model.plan.child.path.join(format!("storage.{ext}"));
            let overlay = model.plan.child.path.join(format!("overlay.{ext}"));
            disk(&storage);
            disk(&overlay);
            let name = Some(model.record.name.as_str());
            let paths = ManagerPaths::capture_paths(&model.plan, name, &storage, &overlay).unwrap();
            paths
                .matches_collected_paths(&model.plan, name, None, &storage, &overlay)
                .unwrap();
            assert!(paths
                .matches_collected_paths(&model.plan, name, Some(42), &storage, &overlay)
                .is_err());
            assert!(paths
                .matches_collected_paths(&model.plan, name, None, &overlay, &storage)
                .is_err());
            if ext == "qcow2" {
                // This was the old pre-handoff disposal guard, although boot
                // selected the original QCOW2 files through ExportDisk.
                assert_ne!(
                    storage,
                    model
                        .plan
                        .child
                        .path
                        .join(smolvm::storage::STORAGE_DISK_FILENAME)
                );
                assert_ne!(
                    overlay,
                    model
                        .plan
                        .child
                        .path
                        .join(smolvm::storage::OVERLAY_DISK_FILENAME)
                );
            }
        }
    }
    #[test]
    fn historical_paths_survive_namespace_removal_but_do_not_qualify_live_collection() {
        let model = identity_model(true);
        let storage = model.plan.child.path.join("storage.qcow2");
        let overlay = model.plan.child.path.join("overlay.qcow2");
        disk(&storage);
        disk(&overlay);
        let name = Some(model.record.name.as_str());
        let paths = ManagerPaths::capture_paths(&model.plan, name, &storage, &overlay).unwrap();
        std::fs::remove_dir_all(&model.plan.child.path).unwrap();
        paths
            .matches_paths(&model.plan, name, &storage, &overlay)
            .unwrap();
        assert!(ManagerPaths::capture_paths(&model.plan, name, &storage, &overlay).is_err());
        assert!(super::super::collection::verify_manager_disks(
            &model.plan,
            name,
            &storage,
            &overlay
        )
        .is_err());
    }
    #[test]
    fn captured_paths_cannot_adopt_newly_preferred_disks_or_a_replacement_directory() {
        let model = identity_model(true);
        let storage = model.plan.child.path.join("storage.raw");
        let overlay = model.plan.child.path.join("overlay.raw");
        disk(&storage);
        disk(&overlay);
        let name = Some(model.record.name.as_str());
        let paths = ManagerPaths::capture_paths(&model.plan, name, &storage, &overlay).unwrap();
        let qcow = model.plan.child.path.join("storage.qcow2");
        disk(&qcow);
        assert!(ManagerPaths::capture_paths(&model.plan, name, &storage, &overlay).is_err());
        assert!(paths
            .matches_paths(&model.plan, name, &qcow, &overlay)
            .is_err());
        paths
            .matches_paths(&model.plan, name, &storage, &overlay)
            .unwrap();
        std::fs::rename(
            &model.plan.child.path,
            model.plan.child.path.with_extension("moved"),
        )
        .unwrap();
        std::fs::create_dir(&model.plan.child.path).unwrap();
        std::fs::set_permissions(
            &model.plan.child.path,
            std::fs::Permissions::from_mode(0o700),
        )
        .unwrap();
        disk(&storage);
        disk(&overlay);
        assert!(ManagerPaths::capture_paths(&model.plan, name, &storage, &overlay).is_err());
        // The historical locator does not authorize use of this replacement:
        // every mutating continuation still verifies its original plan/row.
        paths
            .matches_paths(&model.plan, name, &storage, &overlay)
            .unwrap();
        assert!(model.plan.verify().is_err());
    }
}

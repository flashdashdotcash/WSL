# Sparse VHD reclamation reliability lab

This investigation targets **actual host disk allocation**, not the logical VHDX file length.
The branch intentionally does not change WSL's default: sparse mode remains experimental.

## Confirmed source behavior

| Component | Source | Finding |
|---|---|---|
| Configuration | src/windows/common/WslCoreConfig.h | EnableSparseVhd defaults to false |
| New VHD creation | src/windows/common/WslCoreFilesystem.cpp::CreateVhd | Passes CREATE_VIRTUAL_DISK_FLAG_SPARSE_FILE |
| Existing VHD conversion | src/windows/service/exe/LxssUserSession.cpp::SetSparse | Uses FSCTL_SET_SPARSE, not a scan of ext4 free blocks |
| Guest root mount | src/windows/service/exe/WslCoreVm.cpp | Requests discard,errors=remount-ro,data=ordered |
| Manual compact | CompactDistribution -> TrimDistribution -> Linux ProcessTrimDistributionMessage -> CompactVirtualDisk | Offline fsck/discard precedes Windows compaction on a stopped distro |
| Existing test | test/windows/wsl/SimpleTests.cpp::CheckSparse | Verifies only the sparse file attribute |

Windows' virtual-disk / HCS stack performs the actual guest-block-to-VHDX
translation; it is **not** implemented in the visible WSL repository.
Blindly punching holes using guest block offsets in the backing .vhdx is unsafe
because a VHDX contains metadata and its own block-allocation mapping.

The Windows FSCTL_SET_SPARSE protocol specifies that setting the attribute
does not deallocate already allocated clusters. Disabling sparse may allocate
previously sparse ranges and fail partway. Simply toggling a file attribute
is therefore not proof that reclaim works.

## Concrete hardening change on this branch

Linux ProcessTrimDistributionMessage previously logged an error but returned
success to the service even when e2fsck failed.

This branch:
- accepts e2fsck statuses 0 (clean) and 1 (filesystem corrected);
- reports genuine trim failures back to WslCoreVm::TrimDistribution;
- retains the existing best-effort fallback: the service logs that failure
  and still calls CompactVirtualDisk.

This improves diagnostics and correctness of error reporting, **not** the
underlying Windows live sparse discard pipeline.

The diagnostic probe (`diagnostics/test-sparse-reclaim.ps1`) also includes:
- Dynamic VHDX discovery: searches the distro directory for any `.vhdx`
  file instead of assuming `ext4.vhdx`, so the probe works if WSL uses a
  versioned or alternative name.
- Terminate-before-measure: the distro is stopped before each host-allocation
  snapshot so the VHDX is not held open by the WSL virtual machine, giving
  accurate `GetCompressedFileSizeW` readings at the restart checkpoint.

## Reproduction with disposable distros

Run PowerShell on Windows with WSL 3.x and a compatible rootfs TAR:

~~~powershell
.\diagnostics\test-sparse-reclaim.ps1 -RootfsTar "C:\temp\ubuntu-rootfs.tar" -WriteMiB 1024 -Cycles 3 -IncludeDynamicControl
~~~

The TAR must contain sh, dd, sha256sum, findmnt, lsblk and fstrim.

The script:
1. Imports randomly named disposable WSL2 distros, one sparse and optionally
   one dynamically expanding control. It never changes an existing distro.
2. Reads both logical length and real host allocation with GetCompressedFileSizeW.
3. Writes incompressible random bytes, verifies SHA-256, and terminates/restarts
   only the test distro to check data persistence.
4. Deletes the temporary data, runs fstrim -v /, and polls host allocation.
5. Verifies an independent persistent sentinel checksum survives the discard.
6. Repeats the workload, writing CSV/JSON diagnostics in
   %TEMP%\wsl-sparse-reclaim-lab\results-<run-id>.
7. Unregisters the test distros automatically unless -KeepDistros was supplied.

The probe never runs wsl --shutdown, never changes .wslconfig, and never
modifies a user's working ext4.vhdx. The rootfs TAR must be supplied
separately; the script does not download anything.

A PASS means reclamation exceeded the configured threshold in *that run*,
not that sparse VHDs are safe to enable by default. A reclaim failure
does not by itself establish data corruption.

## Hypotheses to distinguish

| Observation | Next layer to investigate |
|---|---|
| Sparse attribute never set | WSL VHD creation or conversion |
| Sparse attribute set, but fstrim fails | Guest block-device discard capability |
| fstrim succeeds but host allocation remains | Virtual-disk discard -> Windows allocation mapping |
| Live discard doesn't reclaim, offline --compact does | Live path versus offline compaction |
| Fresh sparse works but converted sparse fails | FSCTL_SET_SPARSE semantics, existing VHD blocks |
| Checksum changes or VHD fails to attach | Halt tests, preserve the image, analyze corruption on a copy |

## Requirements before default-on

- Windows-version and filesystem compatibility matrix (NTFS/ReFS).
- Repeated actual host allocation reclamation, not just a sparse file flag.
- Consistent data hashes under repeated write/delete/discard cycles.
- Separate crash and out-of-space fault-injection testing in isolated Windows VMs.
- Concurrent WSL imports, exports, restarts and disk operations.
- Safe fallback to ordinary dynamic VHDs.
- Privacy-preserving telemetry for allocated bytes, sparse state and errors.
  Upstream PR #41844 already proposes telemetry and should not be duplicated.

## Related upstream work

- https://github.com/microsoft/WSL/issues/4699
- https://github.com/microsoft/WSL/issues/12103
- https://github.com/microsoft/WSL/issues/10609
- https://github.com/microsoft/WSL/issues/41837
- https://github.com/microsoft/WSL/pull/40481
- https://github.com/microsoft/WSL/pull/41726
- https://github.com/microsoft/WSL/pull/41844
- https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-fscc/6a884fe5-3da1-4abb-84c4-f419d349d878

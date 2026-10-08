#!/usr/bin/env python3
"""Stage the exact local whisper.cpp closure without materializing dataless assets."""

import importlib.util
import hashlib
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile


spec = importlib.util.spec_from_file_location(
    "speech_provision", Path(__file__).with_name("provision-speech-model.py")
)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)

Asset = tuple[str, str, int, str, int, str]
MODEL = ("", "model/ggml-base.en.bin", 147964211,
         "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
         147964211, "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002")
BACKEND = "/opt/homebrew/Cellar/ggml/0.25.3/libexec"
ASSETS: tuple[Asset, ...] = (
    ("/opt/homebrew/Cellar/whisper.cpp/1.9.4/bin/whisper-cli",
     "bin/whisper-cli", 660848, "13650fc8ffaaa4e637c6951f7d2e492916877e70bd1b7a266fbfd0bdc597719e",
     657008, "02b6938b489381f6a528a4a8883264ea56eed76c7423b803d21394297b2c4834"),
    ("/opt/homebrew/Cellar/whisper.cpp/1.9.4/lib/libwhisper.1.9.4.dylib",
     "lib/libwhisper.1.dylib", 423568, "c2c6624410d3308238d855b9ad1c201e578017c435616d644a1bbcbb3f030153",
     421104, "eca0dcf2178dd2f1903ebb502f10903932ee764070cc46d63d14ffd3d1fa024b"),
    ("/opt/homebrew/Cellar/ggml/0.25.3/lib/libggml.0.25.3.dylib",
     "lib/libggml.0.dylib", 61232, "35ddda50d5c05a831509e1d15258ad81e6809e4f36d3b5baec6e6bac2811ad37",
     60896, "02256126859de0555e777e78e6447d8102b0edea4a995f275c3106b3a7c65db8"),
    ("/opt/homebrew/Cellar/ggml/0.25.3/lib/libggml-base.0.25.3.dylib",
     "lib/libggml-base.0.dylib", 518960, "0678bbbf2a6102efdc0d56278091652b6cdac3e93fe5cfd0e8a85404cadf3ca4",
     515952, "84a8ec249803e5da0c28800b0c1699c8a92e1b52e6d2931faecacf35e4901126"),
    ("/opt/homebrew/Cellar/libomp/23.1.2/lib/libomp.dylib",
     "lib/libomp.dylib", 725984, "cb679440b0af57131274b6c0bcc11b8c18ef7ad45e2a6625ef57e90379fc2ae4",
     721776, "66ea5824d7cf242e3a00e00480d7ccd60e100bd0665bdb69dabb2326728e38f4"),
    (f"{BACKEND}/libggml-blas.so",
     "libexec/libggml-blas.so", 59424, "1b0371cdd0f55c70e99eaa0461e1e997a8d67aa3b517f2b7377002659fb13192",
     59216, "99ca2ef77f56896b07351ac8a03e242b28201546a417b2ff6ee5a9c395b252e2"),
    (f"{BACKEND}/libggml-cpu-apple_m1.so",
     "libexec/libggml-cpu-apple_m1.so", 605024, "93876b87b7e99c0147bb800f1ef823cc80b5648eb66a5ea20cd2383d235920cb",
     601520, "e01bd177f9889e95efb990203fde896910f78237e96a798e115fa662f025b46a"),
    (f"{BACKEND}/libggml-cpu-apple_m2_m3.so",
     "libexec/libggml-cpu-apple_m2_m3.so", 605040, "0bc8edc2dfd4bbb416dfe09351265239b168b8ecf0bb234f767b936656a4ae24",
     601520, "827a2d6f05db7bd2fc2e4ee73e767ca54d381a86de5f1a71e2e6f91df12b6c8e"),
    (f"{BACKEND}/libggml-cpu-apple_m4.so",
     "libexec/libggml-cpu-apple_m4.so", 605024, "ccf7c056d61a8dc9a6b461dcbc19d447cbddc2a8b66f788c0f632b2ea4657e42",
     601520, "c2fb157016389e35b61695a3c021675b715c6285b1caefdfa056a1d5e8624905"),
)


def _source(path):
    path = Path(os.path.abspath(path))
    parents = policy._parent_identities(path)
    try:
        info = os.lstat(path)
    except OSError as error:
        raise policy.ProvisionError("Staging asset absent") from error
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
            or getattr(info, "st_flags", 0) & policy.SF_DATALESS
            or info.st_dev != os.stat("/private/tmp").st_dev):
        raise policy.ProvisionError("Staging asset is linked, dataless or not a local regular file")
    return path, parents, info


def _require_unchanged(path, identity):
    _, parents, info = _source(path)
    if (policy._identity(info), parents) != identity:
        raise policy.ProvisionError("Staging source identity changed")


def _copy_pinned(source, destination, size, digest, identity):
    source, parents, pathname = _source(source)
    if (policy._identity(pathname), parents) != identity:
        raise policy.ProvisionError("Staging source identity changed before copy")
    try:
        fd = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        raise policy.ProvisionError("Staging asset cannot be opened locally") from error
    try:
        before = os.fstat(fd)
        if (policy._identity(pathname) != policy._identity(before)
                or before.st_size != size or getattr(before, "st_flags", 0) & policy.SF_DATALESS):
            raise policy.ProvisionError("Staging asset changed before copy")
        sha = hashlib.sha256()
        output = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL
                         | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
        try:
            with os.fdopen(os.dup(fd), "rb") as source_stream, os.fdopen(os.dup(output), "wb") as target_stream:
                for chunk in iter(lambda: source_stream.read(1024 * 1024), b""):
                    sha.update(chunk)
                    target_stream.write(chunk)
                target_stream.flush()
                os.fsync(target_stream.fileno())
            os.fchmod(output, stat.S_IMODE(before.st_mode))
            if (sha.hexdigest() != digest or policy._identity(before) != policy._identity(os.fstat(fd))
                    or policy._identity(before) != policy._identity(os.lstat(source))
                    or parents != policy._parent_identities(source)):
                raise policy.ProvisionError("Staging asset changed or failed reviewed SHA-256")
            staged = os.fstat(output)
            if (staged.st_size != size or staged.st_nlink != 1
                    or getattr(staged, "st_flags", 0) & policy.SF_DATALESS
                    or policy._identity(staged) != policy._identity(os.lstat(destination))):
                raise policy.ProvisionError("Staged asset changed during copy")
        finally:
            os.close(output)
    finally:
        os.close(fd)
    policy._check_file(destination, size, digest, owner_private=False)


def _child_policy():
    get_policy, set_policy = policy._policy_functions()
    kind = policy.IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
    scope = policy.IOPOL_SCOPE_PROCESS
    if set_policy(kind, scope, policy.IOPOL_MATERIALIZE_DATALESS_FILES_OFF) != 0:
        raise policy.ProvisionError("Cannot protect staging subprocess")
    if get_policy(kind, scope) != policy.IOPOL_MATERIALIZE_DATALESS_FILES_OFF:
        raise policy.ProvisionError("Staging subprocess policy did not take effect")


def _run(*args):
    subprocess.run(args, check=True, preexec_fn=_child_policy,
                   stdout=subprocess.DEVNULL, timeout=120)


def _relocate(stage):
    ggml = "/opt/homebrew/opt/ggml/lib/"
    omp = "/opt/homebrew/opt/libomp/lib/libomp.dylib"
    for name in ("bin/whisper-cli", "lib/libwhisper.1.dylib"):
        _run("/usr/bin/install_name_tool", "-change", ggml + "libggml.0.dylib",
             "@loader_path/../lib/libggml.0.dylib", "-change",
             ggml + "libggml-base.0.dylib", "@loader_path/../lib/libggml-base.0.dylib",
             str(stage / name))
    _run("/usr/bin/install_name_tool", "-change", "@loader_path/../lib/libggml.0.dylib",
         "@loader_path/libggml.0.dylib", "-change", "@loader_path/../lib/libggml-base.0.dylib",
         "@loader_path/libggml-base.0.dylib", str(stage / "lib/libwhisper.1.dylib"))
    _run("/usr/bin/install_name_tool", "-change", "@rpath/libggml-base.0.dylib",
         "@loader_path/libggml-base.0.dylib", str(stage / "lib/libggml.0.dylib"))
    _run("/usr/bin/install_name_tool", "-change", omp, "@loader_path/libomp.dylib",
         str(stage / "lib/libggml-base.0.dylib"))
    for name in ("libggml-blas.so", "libggml-cpu-apple_m1.so",
                 "libggml-cpu-apple_m2_m3.so", "libggml-cpu-apple_m4.so"):
        _run("/usr/bin/install_name_tool", "-change", "@rpath/libggml-base.0.dylib",
             "@loader_path/../lib/libggml-base.0.dylib", "-change", omp,
             "@loader_path/../lib/libomp.dylib", str(stage / "libexec" / name))
    for name in (asset[1] for asset in ASSETS):
        _run("/usr/bin/codesign", "--force", "--sign", "-", str(stage / name))


def stage(model, assets=ASSETS, transform=_relocate):
    if not os.path.isabs(model):
        raise policy.ProvisionError("Expected one absolute, already provisioned model path")
    stage_path = None
    try:
        with policy.without_materializing_dataless():
            entries = ((model, *MODEL[1:]), *assets)
            # Admission is complete before creating a stage or executing any tool.
            for index, (source, _, size, digest, _, _) in enumerate(entries):
                policy._check_file(source, size, digest, owner_private=index == 0)
            identities = []
            for source, *_ in entries:
                _, parents, info = _source(source)
                identities.append((policy._identity(info), parents))
            stage_path = Path(tempfile.mkdtemp(prefix="ww-speech-", dir="/private/tmp"))
            policy.private_directory(stage_path)
            for name in ("bin", "lib", "libexec", "model"):
                (stage_path / name).mkdir(mode=0o700)
            for (source, target, size, digest, _, _), identity in zip(entries, identities):
                _require_unchanged(source, identity)
                _copy_pinned(source, stage_path / target, size, digest, identity)
            transform(stage_path)
            for _, target, _, _, size, digest in entries:
                policy._check_file(stage_path / target, size, digest, owner_private=False)
            for index, ((source, _, size, digest, _, _), identity) in enumerate(zip(entries, identities)):
                _require_unchanged(source, identity)
                policy._check_file(source, size, digest, owner_private=index == 0)
    except BaseException:
        if stage_path is not None:
            shutil.rmtree(stage_path)
        raise
    return stage_path


def main():
    if len(sys.argv) != 2 or not os.path.isabs(sys.argv[1]):
        print("Expected one absolute, already provisioned model path", file=sys.stderr)
        sys.exit(2)
    try:
        result = stage(sys.argv[1])
    except (policy.ProvisionError, OSError, subprocess.SubprocessError) as error:
        sys.exit(f"Speech stage refused: {error}")
    print(result)


if __name__ == "__main__":
    main()

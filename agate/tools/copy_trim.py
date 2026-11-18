#!/usr/bin/env python3
"""Copy an iOS root tree into an HFS+ volume with HFS compression, leaving out
what a bring-up boot does not need, so the root fits the ~4.9 GiB free tail of
the agate `super` partition.

  copy_trim.py SRC DST [--cryptex]      (run as root on macOS)

Directories that contain nothing to drop are copied whole with
`ditto --hfsCompression` (owners, modes, xattrs, ACLs and hard links kept);
the parents of dropped paths are walked so only the kept children are copied.
ML weight files in frameworks are deleted right after each framework is
copied, so the volume never has to hold them.
"""
import fnmatch
import os
import subprocess
import sys

# Dropped from the OS volume (paths relative to the root).
DROP_OS = [
    'System/Library/LinguisticData',          # text prediction dictionaries
    'System/Library/PreinstalledAssetsV2',    # preinstalled ML assets
    'System/Library/Health',
    'System/Library/NanoTimeKit',             # Apple Watch faces
    'System/Library/Fonts/CoreAddition',      # extra families (system UI fonts stay)
    'System/Library/Fonts/LanguageSupport',   # CJK and other scripts
    'System/Library/Fonts/AppFonts',
    'System/Library/PrivateFrameworks/TextToSpeechMauiSupport.framework',
    'System/Library/PrivateFrameworks/NanoUniverse.framework',
    'System/Library/PrivateFrameworks/AvatarKit.framework',
    'System/Library/PrivateFrameworks/CameraEffectsKit.framework',
    'private/var/staged_system_apps',         # Books, Podcasts, ... installers
    'usr/standalone/update',                  # baseband update firmware
    'Applications/AppStore.app',
    'Applications/SharingViewService.app',
    'Applications/GameCenterWidgets.app',
    'Applications/HDSViewService.app',
    'Applications/DiagnosticsService.app',
]
# Dropped from the SystemOS cryptex.
DROP_CRYPTEX = [
    'System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64.symbols',
]
# Walked one level deeper so per-framework weight deletion can run.
WALK = ['System/Library/Frameworks', 'System/Library/PrivateFrameworks']
WEIGHT_GLOBS = ['*.weights', '*.weights_nonane']


def run(*cmd):
    subprocess.run(cmd, check=True)


def mkdir_like(src, dst):
    st = os.lstat(src)
    os.makedirs(dst, exist_ok=True)
    os.chown(dst, st.st_uid, st.st_gid)
    os.chmod(dst, st.st_mode & 0o7777)


def drop_weights(path):
    n = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            if any(fnmatch.fnmatch(f, g) for g in WEIGHT_GLOBS):
                os.unlink(os.path.join(root, f))
                n += 1
    return n


def copy(src, dst, rel, drop, walk):
    s = os.path.join(src, rel) if rel else src
    d = os.path.join(dst, rel) if rel else dst
    if rel in drop:
        print('drop', rel, flush=True)
        return
    if rel and os.path.islink(s):
        # iOS links many frameworks into the cryptexes; the targets do not
        # exist yet, so ditto cannot resolve them: recreate the link as is.
        st = os.lstat(s)
        os.symlink(os.readlink(s), d)
        os.lchown(d, st.st_uid, st.st_gid)
        return
    descend = rel in walk or any(p.startswith(rel + '/') or not rel for p in drop + walk)
    if not descend or not os.path.isdir(s):
        run('ditto', '--hfsCompression', s, d)
        if any(rel.startswith(w + '/') for w in WALK):
            n = drop_weights(d)
            if n:
                print(f'weights {n} {rel}', flush=True)
        return
    mkdir_like(s, d)
    for name in sorted(os.listdir(s)):
        copy(src, dst, os.path.join(rel, name) if rel else name, drop, walk)


def main():
    if len(sys.argv) < 3 or os.geteuid() != 0:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    cryptex = '--cryptex' in sys.argv[3:]
    drop = DROP_CRYPTEX if cryptex else DROP_OS
    walk = [] if cryptex else WALK
    copy(src, dst, '', drop, walk)


if __name__ == '__main__':
    main()

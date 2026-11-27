"""Package the in-game manager after compiling Embedded.m for arm64 iOS."""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

FRAMEWORK = "SDVModGarden"
APP = "Payload/SDViOS.app/"


def prepare_binary(path, dependency=None, sig_capacity=128*1024):
    data = bytearray(path.read_bytes())
    if data[:4] != bytes.fromhex("cffaedfe"):
        raise ValueError("Expected a thin 64-bit Mach-O")
    count, size = struct.unpack_from("<II", data, 16)
    end = 32 + size
    pos = 32
    sections = []
    linkedit = None
    sig = None
    for _ in range(count):
        cmd, length = struct.unpack_from("<II", data, pos)
        if cmd == 25:
            name = data[pos+8:pos+24].rstrip(b"\0")
            if name == b"__LINKEDIT":
                linkedit = pos
            for j in range(struct.unpack_from("<I", data, pos+64)[0]):
                offset = struct.unpack_from("<I", data, pos+72+80*j+48)[0]
                if offset:
                    sections.append(offset)
        if cmd == 29:
            sig = pos
        pos += length
    commands = bytearray()
    if dependency:
        name = dependency.encode() + b"\0"
        if name not in data[32:end]:
            length = (24+len(name)+7) & ~7
            commands.extend(struct.pack("<6I", 12,length,24,0,0x10000,0x10000)+name.ljust(length-24,b"\0"))
            count += 1
    if sig is None:
        offset = (len(data)+15) & ~15
        # Scale code-signature capacity dynamically for large Hybrid AOT binaries (~42 MB+ needs >600 KB!)
        min_needed = (((len(data) // 4096) + 128) * 80 + 65536 + 16383) & ~16383
        capacity = max(sig_capacity, min_needed)
        data.extend(bytes(offset+capacity-len(data)))
        commands.extend(struct.pack("<4I",29,16,offset,capacity))
        count += 1
        if linkedit is None:
            raise ValueError("Missing link-edit segment")
        n = len(data)-struct.unpack_from("<Q", data, linkedit+40)[0]
        struct.pack_into("<Q",data,linkedit+32,(n+16383) & ~16383)
        struct.pack_into("<Q",data,linkedit+48,n)
    if end + len(commands) > min(sections) or any(data[end:end+len(commands)]):
        raise ValueError("Insufficient reserved load-command space")
    data[end:end+len(commands)] = commands
    struct.pack_into("<II",data,16,count,size+len(commands))
    path.write_bytes(data)


def validate_macho(data, label, is_dylib=False, require_chained=True):
    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack_from("<8I", data, 0)
    assert magic == 0xfeedfacf, f"{label}: not 64-bit Mach-O"
    assert filetype == (6 if is_dylib else 2), f"{label}: unexpected filetype {filetype}"
    pos = 32
    segs = []
    has_chained = False
    has_sig = False
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", data, pos)
        if cmd == 0xe and is_dylib:
            raise AssertionError(f"{label}: illegal LC_LOAD_DYLINKER in MH_DYLIB (breaks iOS 26/27 dyld!)")
        if cmd == 0x80000034:
            has_chained = True
        if cmd == 0x1d:
            off, csz = struct.unpack_from("<2I", data, pos + 8)
            assert off + csz == len(data), f"{label}: LC_CODE_SIGNATURE end {hex(off+csz)} != filelen {hex(len(data))}"
            has_sig = True
        if cmd == 0x19:
            seg = data[pos+8:pos+24].rstrip(b"\0").decode()
            va, vs, fo, fs = struct.unpack_from("<4Q", data, pos + 24)
            assert vs % 0x4000 == 0, f"{label}: segment {seg} vmsize {hex(vs)} not 16KB aligned!"
            if seg not in ("__PAGEZERO", "__LINKEDIT"):
                assert fs % 0x4000 == 0, f"{label}: segment {seg} filesize {hex(fs)} not 16KB aligned!"
                assert fs <= vs, f"{label}: segment {seg} filesize > vmsize"
                segs.append((seg, va, vs))
            elif seg == "__LINKEDIT":
                assert fo + fs == len(data), f"{label}: __LINKEDIT end {hex(fo+fs)} != filelen {hex(len(data))}"
                segs.append((seg, va, vs))
        pos += sz
    for a, b in zip(segs, segs[1:]):
        assert a[1] + a[2] == b[1], f"{label}: VM gap between {a[0]} ({hex(a[1]+a[2])}) and {b[0]} ({hex(b[1])})"
    if require_chained:
        assert has_chained, f"{label}: missing LC_DYLD_CHAINED_FIXUPS"
    assert has_sig, f"{label}: missing LC_CODE_SIGNATURE"
    assert bytes.fromhex("fade0cc0") in data, f"{label}: missing SuperBlob signature"


def build(base, library, signer, output, host_dll=None, touch_dll=None, lidgren_dll=None, launcher_only=False, use_scene=True, min_ios="14.0", smapi_from=None):
    script = Path(__file__).resolve().parent
    mod_root = script if (script / "SDVMobileControls").is_dir() else (script.parent / "ModGarden")
    with tempfile.TemporaryDirectory() as temp, zipfile.ZipFile(base) as original:
        root = Path(temp)
        if launcher_only:
            for item in original.infolist():
                if "/BundledGame/" in item.filename or "/BundledCompatibility/" in item.filename:
                    continue
                original.extract(item, root)
        else:
            original.extractall(root)
        app = root/APP
        fw = app/"Frameworks"/(FRAMEWORK+".framework")
        fw.mkdir(parents=True, exist_ok=True)
        if launcher_only:
            for strip_dir in ("BundledGame", "BundledCompatibility"):
                sd = app / strip_dir
                if sd.exists():
                    shutil.rmtree(sd)
            # Bundle ONLY open-source SMAPI 4.5.2 (LGPL-3.0, zero ConcernedApe game files) inside SDVModGarden.framework/BundledSMAPI/
            smapi_dir = fw / "BundledSMAPI"
            smapi_dir.mkdir(parents=True, exist_ok=True)
            smapi_dll_key = APP + "BundledCompatibility/StardewModdingAPI.dll"
            si_prefix = APP + "BundledGame/smapi-internal/"
            smapi_src = original
            extra_smapi_zip = None
            if smapi_dll_key not in original.NameToInfo and smapi_from and Path(smapi_from).is_file():
                extra_smapi_zip = zipfile.ZipFile(smapi_from)
                smapi_src = extra_smapi_zip
            try:
                if smapi_dll_key in smapi_src.NameToInfo:
                    (smapi_dir / "StardewModdingAPI.dll").write_bytes(smapi_src.read(smapi_dll_key))
                for item in smapi_src.infolist():
                    if not item.is_dir() and item.filename.startswith(si_prefix):
                        rel = item.filename[len(si_prefix):]
                        if rel.lower().endswith(".xml"):
                            continue
                        dst = smapi_dir / "smapi-internal" / rel
                        dst.parent.mkdir(parents=True, exist_ok=True)
                        dst.write_bytes(smapi_src.read(item.filename))
                if (smapi_dir / "smapi-internal").is_dir():
                    for xml_doc in list((smapi_dir / "smapi-internal").rglob("*.xml")):
                        xml_doc.unlink(missing_ok=True)
                # Supplement non-AOT compatibility helper DLLs if missing from an upstream Hybrid AOT base IPA
                if extra_smapi_zip is not None:
                    for helper_dll in (
                        "GalaxyCSharp.dll",
                        "Steamworks.NET.dll",
                        "Microsoft.Extensions.DependencyInjection.Abstractions.dll",
                        "System.Data.HashFunction.Core.dll",
                    ):
                        hkey = APP + helper_dll
                        if not (app / helper_dll).exists() and hkey in extra_smapi_zip.NameToInfo:
                            (app / helper_dll).write_bytes(extra_smapi_zip.read(hkey))
            finally:
                if extra_smapi_zip is not None:
                    extra_smapi_zip.close()
        (fw/FRAMEWORK).write_bytes(Path(library).read_bytes())
        prepare_binary(fw/FRAMEWORK, sig_capacity=48*1024)
        (fw/"Info.plist").write_bytes(plistlib.dumps(dict(CFBundleExecutable=FRAMEWORK,
            CFBundleName=FRAMEWORK,CFBundleIdentifier="dev.stardewmobile.gardenkit",
            CFBundlePackageType="FMWK",CFBundleVersion="112",CFBundleShortVersionString="1.1.2",
            MinimumOSVersion=min_ios,CFBundleSupportedPlatforms=["iPhoneOS"])))
        # Remove stale debug get-task-allow archived-expanded-entitlements.xcent (can conflict with Enterprise/TXM signers on iOS 26/27)
        stale_xcent = app / "archived-expanded-entitlements.xcent"
        if stale_xcent.exists():
            stale_xcent.unlink()
        # Bundle open-source SDVMobileControls SMAPI mod inside SDVModGarden.framework/BundledMods/
        mc_src = mod_root / "SDVMobileControls"
        mc_dll = mc_src / "bin" / "Release" / "net6.0" / "SDVMobileControls.dll"
        mc_man = mc_src / "manifest.json"
        if not mc_dll.is_file() or not mc_man.is_file():
            raise FileNotFoundError(f"Missing required SDVMobileControls build output: {mc_dll}")
        mc_dst = fw / "BundledMods" / "SDVMobileControls"
        mc_dst.mkdir(parents=True, exist_ok=True)
        (mc_dst / "manifest.json").write_bytes(mc_man.read_bytes())
        (mc_dst / "SDVMobileControls.dll").write_bytes(mc_dll.read_bytes())
        for boot_asset in ("boot_bg.jpg", "boot_title_main.png", "boot_title_sub.png"):
            ba_path = mod_root / boot_asset
            if not ba_path.is_file():
                raise FileNotFoundError(f"Missing required boot screen asset: {ba_path}")
            (fw / boot_asset).write_bytes(ba_path.read_bytes())
        (app/"orchard.png").write_bytes((mod_root/"orchard.png").read_bytes())
        if host_dll:
            (app/"SDViOS.dll").write_bytes(Path(host_dll).read_bytes())
            wrote_mg = False
            for mg_name in ("v7-monogame.dll", "v6-monogame.dll", "v5-monogame.dll"):
                mg_candidate = Path(host_dll).parent / mg_name
                if mg_candidate.is_file():
                    (app/"MonoGame.Framework.dll").write_bytes(mg_candidate.read_bytes())
                    wrote_mg = True
                    break
            if not wrote_mg:
                raise FileNotFoundError(f"Missing patched MonoGame.Framework.dll (v7-monogame.dll) beside {host_dll}")
        if touch_dll:
            td = Path(touch_dll).read_bytes()
            (app/"Mods"/"SDViOSTouchControls"/"SDViOSTouchControls.dll").write_bytes(td)
            (app/"Mods"/"SDViOSTouchControls"/"SDViOSTouchControlsMod.dll").write_bytes(td)
        if lidgren_dll:
            ld_bytes = Path(lidgren_dll).read_bytes()
            (fw/"Lidgren.Network.dll").write_bytes(ld_bytes)
            if not launcher_only:
                (app/"BundledGame"/"Lidgren.Network.dll").write_bytes(ld_bytes)
        prepare_binary(app/"SDViOS", f"@rpath/{FRAMEWORK}.framework/{FRAMEWORK}", sig_capacity=128*1024)
        info = plistlib.loads((app/"Info.plist").read_bytes())
        info.update(
            MinimumOSVersion=min_ios,
            CFBundleShortVersionString="1.1.2",
            CFBundleVersion="1.1.2",
            UIFileSharingEnabled=True,
            LSSupportsOpeningDocumentsInPlace=True,
            UIApplicationSupportsIndirectInputEvents=True,
            NSPhotoLibraryUsageDescription="Garden Launcher cần truy cập Thư viện Ảnh/Video khi bạn đính kèm ảnh chụp màn hình hoặc video minh họa vào báo lỗi.",
            LSEnvironment={"MONO_GC_PARAMS": "nursery-size=4m,soft-heap-limit=384m,evacuation-threshold=66"},
            NSLocalNetworkUsageDescription="Stardew Mobile cần quyền mạng cục bộ để tạo phòng (Host) và kết nối chơi chung Co-op qua LAN / IP trực tiếp.",
            NSBonjourServices=["_stardew._udp", "_lidgren._udp"],
            NSAppTransportSecurity={
                "NSAllowsArbitraryLoads": True,
                "NSAllowsLocalNetworking": True,
            },
        )
        if use_scene:
            info["UIApplicationSceneManifest"] = {
                "UIApplicationSupportsMultipleScenes": False,
                "UISceneConfigurations": {
                    "UIWindowSceneSessionRoleApplication": [
                        {
                            "UISceneConfigurationName": "Default Configuration",
                            "UISceneDelegateClassName": "SDVSceneDelegate",
                        }
                    ]
                },
            }
            info["UIDesignRequiresCompatibility"] = True
        else:
            info.pop("UIApplicationSceneManifest", None)
            info.pop("UIDesignRequiresCompatibility", None)
        if launcher_only:
            info.update(
                CFBundleDisplayName="Garden Launcher",
                CFBundleName="Garden Launcher",
                CFBundleIdentifier="com.gardenlauncher.sdvios",
                NSLocalNetworkUsageDescription="Garden Launcher cần quyền mạng cục bộ để tạo phòng (Host) và kết nối chơi chung Co-op qua LAN / IP trực tiếp.",
                CFBundleIcons={
                    "CFBundlePrimaryIcon": {
                        "CFBundleIconFiles": ["AppIcon20x20", "AppIcon29x29", "AppIcon40x40", "AppIcon60x60"],
                    }
                },
                **{
                    "CFBundleIcons~ipad": {
                        "CFBundlePrimaryIcon": {
                            "CFBundleIconFiles": ["AppIcon20x20", "AppIcon29x29", "AppIcon40x40", "AppIcon60x60", "AppIcon76x76", "AppIcon83.5x83.5"],
                        }
                    }
                },
            )
            icon_src = mod_root / "GardenLauncherIcons"
            if icon_src.is_dir():
                shutil.rmtree(app / "AppIcons", ignore_errors=True)
                for stale_icon in list(app.glob("iTunesArtwork*")) + list(app.glob("AppIcon512*")) + list(app.glob("AppIcon1024*")) + list(app.glob("AppIcon-1024*")):
                    stale_icon.unlink(missing_ok=True)
                allowed_prefixes = (
                    "AppIcon20x20",
                    "AppIcon29x29",
                    "AppIcon40x40",
                    "AppIcon60x60",
                    "AppIcon76x76",
                    "AppIcon83.5x83.5",
                )
                for ipng in icon_src.glob("*.png"):
                    if ipng.name.startswith(allowed_prefixes):
                        (app / ipng.name).write_bytes(ipng.read_bytes())
        (app/"Info.plist").write_bytes(plistlib.dumps(info,fmt=plistlib.FMT_BINARY))
        subprocess.run([signer,"-a","-f",str(app)],cwd=temp,check=True)
        pending = Path(output).with_suffix(".building")
        try:
            with zipfile.ZipFile(pending,"w",compression=zipfile.ZIP_DEFLATED,compresslevel=9) as out:
                for p in sorted(app.rglob("*")):
                    if not p.is_file():
                        continue
                    name=p.relative_to(root).as_posix()
                    entry=zipfile.ZipInfo.from_file(p,name)
                    entry.compress_type=zipfile.ZIP_DEFLATED
                    entry.create_system=3
                    executable=p.name in {"SDViOS",FRAMEWORK,"libSkiaSharp"} or p.suffix==".dylib"
                    original_mode = original.getinfo(name).external_attr >> 16 if name in original.NameToInfo else 0
                    entry.external_attr=(0o100755 if executable else (original_mode or 0o100644))<<16
                    out.writestr(entry,p.read_bytes(),compresslevel=9)
            with zipfile.ZipFile(pending) as result:
                assert result.testzip() is None
                if launcher_only:
                    for n in result.namelist():
                        assert "/BundledGame/" not in n and "/BundledCompatibility/" not in n, f"Unexpected bundled game file: {n}"
                        assert Path(n).name.lower() not in {"stardew valley.dll", "xtile.dll", "bmfont.dll", "stardewvalley.gamedata.dll"}, f"Unexpected proprietary DLL: {n}"
                        assert "/Content/" not in n, f"Unexpected Content file: {n}"
                    assert (APP + f"Frameworks/{FRAMEWORK}.framework/BundledSMAPI/StardewModdingAPI.dll") in result.NameToInfo
                    assert (APP + f"Frameworks/{FRAMEWORK}.framework/BundledSMAPI/smapi-internal/metadata.json") in result.NameToInfo
                    if mc_dll.is_file():
                        assert hashlib.sha256(result.read(APP + f"Frameworks/{FRAMEWORK}.framework/BundledMods/SDVMobileControls/SDVMobileControls.dll")).digest() == hashlib.sha256(mc_dll.read_bytes()).digest()
                else:
                    for item in original.infolist():
                        if item.is_dir(): continue
                        assert item.filename in result.NameToInfo
                        if item.filename == APP + "BundledGame/Lidgren.Network.dll" and lidgren_dll:
                            continue
                        if "/BundledGame/" in item.filename or "/BundledCompatibility/" in item.filename:
                            assert item.CRC==result.getinfo(item.filename).CRC
                for p in (app/"SDViOS",fw/FRAMEWORK):
                    b=result.read(p.relative_to(root).as_posix())
                    assert hashlib.sha256(b).digest()==hashlib.sha256(p.read_bytes()).digest()
                    assert bytes.fromhex("fade0cc0") in b
                validate_macho(result.read(APP + "SDViOS"), "SDViOS", is_dylib=False, require_chained=True)
                validate_macho(result.read(APP + f"Frameworks/{FRAMEWORK}.framework/{FRAMEWORK}"), FRAMEWORK, is_dylib=True, require_chained=True)
                if host_dll:
                    assert hashlib.sha256(result.read(APP+"SDViOS.dll")).digest()==hashlib.sha256(Path(host_dll).read_bytes()).digest()
                if touch_dll:
                    th = hashlib.sha256(Path(touch_dll).read_bytes()).digest()
                    assert hashlib.sha256(result.read(APP+"Mods/SDViOSTouchControls/SDViOSTouchControls.dll")).digest()==th
                    assert hashlib.sha256(result.read(APP+"Mods/SDViOSTouchControls/SDViOSTouchControlsMod.dll")).digest()==th
                if lidgren_dll:
                    lh = hashlib.sha256(Path(lidgren_dll).read_bytes()).digest()
                    assert hashlib.sha256(result.read(APP+f"Frameworks/{FRAMEWORK}.framework/Lidgren.Network.dll")).digest()==lh
                    if not launcher_only:
                        assert hashlib.sha256(result.read(APP+"BundledGame/Lidgren.Network.dll")).digest()==lh
            os.replace(pending,output)
        finally:
            pending.unlink(missing_ok=True)


if __name__=="__main__":
    args = list(sys.argv[1:])
    launcher = "--launcher" in args
    if launcher:
        args.remove("--launcher")
    use_scene = "--no-scene" not in args
    if not use_scene:
        args.remove("--no-scene")
    min_ios = "14.0"
    smapi_from = None
    for a in list(args):
        if a.startswith("--min-ios="):
            min_ios = a.split("=", 1)[1]
            args.remove(a)
        elif a.startswith("--smapi-from="):
            smapi_from = a.split("=", 1)[1]
            args.remove(a)
    build(*args, launcher_only=launcher, use_scene=use_scene, min_ios=min_ios, smapi_from=smapi_from)

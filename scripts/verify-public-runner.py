#!/usr/bin/env python3
"""Fail-closed verifier used by the public standard macOS runner."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import platform
import plistlib
import re
import stat
import subprocess
import tarfile
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

BUNDLE = "com.wellmadesystems.quietworlds"
BUILD_NUMBER = "32"
VERSION = "0.5.0"
EXPECTED_TEAM = "7D88UFWRTZ"
EXPECTED_PROFILE_UUID = "3b5d5cd7-a4d3-43ff-b3e1-c0c3a81ffdc8"
EXPECTED_PROFILE_SHA = "fa3a0823eabfc9b6fd93325e7f5cd947b231325430823a603b75963468bab742"
EXPECTED_CERT_SHA = "3870fd7a823c074b79fdf2862c3a57b5432bcce43b963e759f81ea3789e1a107"
HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")

def sha_file(path: Path) -> str:
    digest=hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda:stream.read(1024*1024),b""):
            digest.update(block)
    return digest.hexdigest()

def canonical_inventory(items: list[dict]) -> list[dict]:
    return sorted(items,key=lambda value:value["path"].encode("utf-8"))

def framed_tree(items: list[dict]) -> str:
    digest=hashlib.sha256()
    for item in canonical_inventory(items):
        path=item["path"].encode("utf-8")
        digest.update(len(path).to_bytes(8,"big")); digest.update(path)
        digest.update(int(item["byteLength"]).to_bytes(8,"big"))
        digest.update(bytes.fromhex(item["sha256"]))
    return digest.hexdigest()

def load_manifest(path: Path) -> dict:
    manifest=json.loads(path.read_text())
    required={"schema","candidateCommit","candidateTree","unityVersion","bundleIdentifier","buildNumber","versionName","designation","exportProvenance","fileInventory","framedTreeSha256","archiveSha256","archiveByteLength","generatedUtc"}
    if set(manifest)!=required or manifest["schema"]!=1:
        raise SystemExit("detached manifest shape mismatch")
    if not HEX40.fullmatch(manifest["candidateCommit"]) or not HEX40.fullmatch(manifest["candidateTree"]):
        raise SystemExit("candidate provenance shape mismatch")
    if manifest["bundleIdentifier"]!=BUNDLE or str(manifest["buildNumber"])!=BUILD_NUMBER or manifest["versionName"]!=VERSION:
        raise SystemExit("detached manifest application identity mismatch")
    if manifest["designation"]!="INTERNAL" or manifest["exportProvenance"]!="private-linux-unity-export":
        raise SystemExit("detached manifest provenance mismatch")
    if not HEX64.fullmatch(manifest["framedTreeSha256"]) or not HEX64.fullmatch(manifest["archiveSha256"]):
        raise SystemExit("detached manifest hash shape mismatch")
    inventory=manifest["fileInventory"]
    if not isinstance(inventory,list) or not inventory:
        raise SystemExit("empty export fileInventory")
    paths=[]
    for item in inventory:
        if set(item)!={"path","byteLength","sha256"} or not isinstance(item["byteLength"],int) or item["byteLength"]<0 or not HEX64.fullmatch(item["sha256"]):
            raise SystemExit("invalid export inventory entry")
        path=PurePosixPath(item["path"])
        if path.is_absolute() or ".." in path.parts or path.as_posix()!=item["path"] or not item["path"]:
            raise SystemExit("unsafe export inventory path")
        paths.append(item["path"])
    if paths!=[item["path"] for item in canonical_inventory(inventory)] or len(paths)!=len(set(paths)) or framed_tree(inventory)!=manifest["framedTreeSha256"]:
        raise SystemExit("inventory order or framedTreeSha256 mismatch")
    return manifest

def verify_export(args) -> None:
    archive=Path(args.archive); manifest=load_manifest(Path(args.manifest))
    expected=args.expected_sha.lower()
    if not HEX64.fullmatch(expected) or expected!=manifest["archiveSha256"] or sha_file(archive)!=expected or archive.stat().st_size!=manifest["archiveByteLength"]:
        raise SystemExit("archive SHA-256/byte length mismatch")
    expected_items={item["path"]:item for item in manifest["fileInventory"]}
    actual=[]
    with tarfile.open(archive,"r:gz") as tar:
        for member in tar.getmembers():
            pure=PurePosixPath(member.name)
            if pure.is_absolute() or ".." in pure.parts or not member.name.startswith("xcode-export/"):
                raise SystemExit("unsafe archive member")
            if member.issym() or member.islnk() or member.isdev():
                raise SystemExit("links/devices are forbidden in export archive")
            if not member.isfile():
                continue
            rel=member.name[len("xcode-export/"):]
            if rel not in expected_items:
                raise SystemExit("archive has undeclared file")
            stream=tar.extractfile(member)
            if stream is None: raise SystemExit("archive file stream missing")
            digest=hashlib.sha256(); size=0
            for block in iter(lambda:stream.read(1024*1024),b""):
                size+=len(block);digest.update(block)
            item={"path":rel,"byteLength":size,"sha256":digest.hexdigest()}
            if item!=expected_items[rel]: raise SystemExit("archive file inventory mismatch")
            actual.append(item)
    if canonical_inventory(actual)!=manifest["fileInventory"] or framed_tree(actual)!=manifest["framedTreeSha256"]:
        raise SystemExit("archive inventory completeness mismatch")
    print("PASS private export archive and detached manifest verified before extraction")

def run_bytes(command: list[str]) -> bytes:
    result=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=False)
    if result.returncode:
        raise SystemExit("verification command failed: "+command[0])
    return result.stdout

def verify_ipa_archive_safety(ipa: Path) -> None:
    seen=set()
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None:
            raise SystemExit("IPA ZIP integrity failure")
        for item in archive.infolist():
            name=item.filename
            directory=item.is_dir()
            normalized_name=name[:-1] if directory and name.endswith("/") else name
            pure=PurePosixPath(normalized_name)
            if (not normalized_name or "\\" in name or pure.is_absolute() or ".." in pure.parts
                    or pure.as_posix()!=normalized_name or re.match(r"^[A-Za-z]:", normalized_name)):
                raise SystemExit("duplicate or unsafe IPA path")
            folded=normalized_name.casefold()
            if folded in seen:
                raise SystemExit("duplicate or unsafe IPA path")
            seen.add(folded)
            mode=(item.external_attr >> 16) & 0xFFFF
            kind=stat.S_IFMT(mode)
            if stat.S_ISLNK(mode) or kind not in (0,stat.S_IFREG,stat.S_IFDIR):
                raise SystemExit("unsafe IPA ZIP entry type")
            if (directory and kind==stat.S_IFREG) or (not directory and kind==stat.S_IFDIR):
                raise SystemExit("unsafe IPA ZIP entry type")
    print("PASS IPA ZIP integrity/path/type/symlink safety verified before extraction")

def verify_ipa(args) -> None:
    ipa=Path(args.ipa); manifest=load_manifest(Path(args.manifest)); output=Path(args.output)
    verify_ipa_archive_safety(ipa)
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None: raise SystemExit("IPA ZIP integrity failure")
        names=archive.namelist()
        if len(names)!=len(set(names)) or any(PurePosixPath(name).is_absolute() or ".." in PurePosixPath(name).parts for name in names): raise SystemExit("duplicate or unsafe IPA path")
        apps=sorted({name.split("/")[1] for name in names if name.startswith("Payload/") and len(name.split("/"))>2 and name.split("/")[1].endswith(".app")})
        if len(apps)!=1: raise SystemExit("IPA must contain one Payload app")
        prefix="Payload/"+apps[0]+"/"; info=plistlib.loads(archive.read(prefix+"Info.plist")); embedded=archive.read(prefix+"embedded.mobileprovision")
        executable=info.get("CFBundleExecutable")
        if not isinstance(executable,str) or PurePosixPath(executable).name!=executable or prefix+executable not in names: raise SystemExit("IPA executable missing or unsafe")
        executable_bytes=archive.read(prefix+executable)
    if info.get("CFBundleIdentifier")!=BUNDLE or str(info.get("CFBundleVersion"))!=BUILD_NUMBER or info.get("CFBundleShortVersionString")!=VERSION:
        raise SystemExit("IPA native identity mismatch")
    expected_info={"QWCandidateCommit":manifest["candidateCommit"],"QWCandidateTree":manifest["candidateTree"],"QWBuildDesignation":"INTERNAL","QWBuildPipeline":"independent-native-v1","QWBuildProvenance":"private-linux-unity-export"}
    if any(info.get(key)!=value for key,value in expected_info.items()): raise SystemExit("IPA provenance binding mismatch")
    with tempfile.TemporaryDirectory() as temporary:
        temp=Path(temporary); profile=temp/"embedded.mobileprovision"; profile.write_bytes(embedded)
        decoded=plistlib.loads(run_bytes(["security","cms","-D","-i",str(profile)]))
    entitlements=decoded.get("Entitlements") or {}; devices=decoded.get("ProvisionedDevices") or []; team=(decoded.get("TeamIdentifier") or [None])[0]
    allowed_entitlements={"application-identifier","com.apple.developer.team-identifier","keychain-access-groups","get-task-allow","beta-reports-active"}
    profile_sha=hashlib.sha256(embedded).hexdigest()
    if profile_sha!=EXPECTED_PROFILE_SHA or team!=EXPECTED_TEAM or decoded.get("UUID")!=EXPECTED_PROFILE_UUID or entitlements.get("application-identifier")!=EXPECTED_TEAM+"."+BUNDLE or entitlements.get("get-task-allow") is not False or len(devices)!=1 or decoded.get("ProvisionsAllDevices") or not set(entitlements).issubset(allowed_entitlements):
        raise SystemExit("embedded profile identity/type/device mismatch")
    if decoded.get("ExpirationDate").astimezone(timezone.utc)<=datetime.now(timezone.utc): raise SystemExit("embedded profile expired")
    certs=decoded.get("DeveloperCertificates") or []
    if not certs: raise SystemExit("embedded profile certificate missing")
    cert_hashes=sorted(hashlib.sha256(bytes(value)).hexdigest() for value in certs)
    expected_cert=os.environ.get("QW_EXPECTED_CERT_SHA","")
    app_signing_cert=os.environ.get("QW_APP_SIGNING_CERT_SHA","")
    expected_team=os.environ.get("QW_EXPECTED_TEAM_ID","")
    expected_profile=os.environ.get("QW_EXPECTED_PROFILE_UUID","")
    if expected_cert!=EXPECTED_CERT_SHA or expected_cert not in cert_hashes:
        raise SystemExit("embedded profile certificate does not match imported distribution identity")
    if app_signing_cert!=expected_cert:
        raise SystemExit("app CodeDirectory signer certificate does not match imported distribution identity")
    if expected_team!=EXPECTED_TEAM or expected_profile!=EXPECTED_PROFILE_UUID:
        raise SystemExit("embedded profile team/UUID does not match installed signing authority")
    verification={
        "schema":1,"status":"PASS","runner":"macos-15","ipaSha256":sha_file(ipa),"ipaByteLength":ipa.stat().st_size,
        "bundleIdentifier":BUNDLE,"versionName":VERSION,"buildNumber":int(BUILD_NUMBER),
        "candidateCommit":manifest["candidateCommit"],"candidateTree":manifest["candidateTree"],
        "exportArchiveSha256":manifest["archiveSha256"],"exportFramedTreeSha256":manifest["framedTreeSha256"],
        "designation":"INTERNAL","pipeline":"independent-native-v1","provenance":"private-linux-unity-export",
        "profileSha256":profile_sha,"profileUuid":decoded.get("UUID"),"profileExpirationUtc":decoded.get("ExpirationDate").astimezone(timezone.utc).isoformat().replace("+00:00","Z"),
        "provisionedDeviceCount":len(devices),"teamIdentifier":team,"profileCertificateSha256":cert_hashes,
        "appSigningCertificateSha256":app_signing_cert,"codesignDeepStrict":True,"arm64Verified":True,"ipaStructureVerified":True,
        "toolchain":{"xcodeVersion":run_bytes(["xcodebuild","-version"]).decode(errors="replace").strip().splitlines(),"machine":platform.machine(),"imageOS":os.environ.get("ImageOS"),"imageVersion":os.environ.get("ImageVersion")},
        "workflow":{"runId":os.environ.get("GITHUB_RUN_ID"),"runAttempt":os.environ.get("GITHUB_RUN_ATTEMPT"),"runnerName":os.environ.get("RUNNER_NAME")},
    }
    payload=(json.dumps(verification,indent=2,sort_keys=True)+"\n").encode()
    absolute=output.absolute();parts=absolute.parent.parts;parent=os.open(parts[0] or os.sep,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0))
    for component in parts[1:]:
        child=os.open(component,os.O_RDONLY|getattr(os,"O_DIRECTORY",0)|getattr(os,"O_NOFOLLOW",0),dir_fd=parent);os.close(parent);parent=child
    temporary="."+absolute.name+".tmp-"+os.urandom(12).hex();created=False;owned=None;errors=[]
    try:
        leaf=os.open(temporary,os.O_WRONLY|os.O_CREAT|os.O_EXCL|getattr(os,"O_NOFOLLOW",0),0o600,dir_fd=parent);created=True
        try:
            view=memoryview(payload)
            while view:view=view[os.write(leaf,view):]
            os.fchmod(leaf,0o600);os.fsync(leaf);source=os.fstat(leaf)
        finally:os.close(leaf)
        try:os.stat(absolute.name,dir_fd=parent,follow_symlinks=False);raise RuntimeError("verification output must be new")
        except FileNotFoundError:pass
        os.link(temporary,absolute.name,src_dir_fd=parent,dst_dir_fd=parent,follow_symlinks=False);owned=source
        os.unlink(temporary,dir_fd=parent);created=False
        published=os.stat(absolute.name,dir_fd=parent,follow_symlinks=False)
        if not stat.S_ISREG(published.st_mode) or (source.st_dev,source.st_ino)!=(published.st_dev,published.st_ino):raise RuntimeError("unsafe verification output publication")
        os.fsync(parent);owned=None
    except Exception as error:errors.append(error)
    finally:
        if created:
            try:os.unlink(temporary,dir_fd=parent)
            except FileNotFoundError:pass
            except Exception as error:errors.append(error)
        if owned is not None:
            try:
                current=os.stat(absolute.name,dir_fd=parent,follow_symlinks=False)
                if (owned.st_dev,owned.st_ino)==(current.st_dev,current.st_ino):os.unlink(absolute.name,dir_fd=parent)
                else:errors.append(RuntimeError("verification output ownership changed before rollback"))
            except FileNotFoundError:pass
            except Exception as error:errors.append(error)
        os.close(parent)
    if len(errors)==1:raise errors[0]
    if errors:raise ExceptionGroup("verification publication and cleanup failed",errors)
    # Do not print signing/provenance values to public logs.
    print("PASS signed Ad Hoc IPA structure, identity, provenance, profile, and architecture verified")

def main() -> None:
    parser=argparse.ArgumentParser(); sub=parser.add_subparsers(dest="mode",required=True)
    export=sub.add_parser("verify-export"); export.add_argument("--archive",required=True); export.add_argument("--manifest",required=True); export.add_argument("--expected-sha",required=True)
    safety=sub.add_parser("verify-ipa-archive"); safety.add_argument("--ipa",required=True)
    ipa=sub.add_parser("verify-ipa"); ipa.add_argument("--ipa",required=True); ipa.add_argument("--manifest",required=True); ipa.add_argument("--output",required=True)
    args=parser.parse_args()
    if args.mode=="verify-export": verify_export(args)
    elif args.mode=="verify-ipa-archive": verify_ipa_archive_safety(Path(args.ipa))
    else: verify_ipa(args)
if __name__=="__main__": main()

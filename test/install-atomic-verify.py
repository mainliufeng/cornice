#!/usr/bin/env python3
"""Exercise real rename exchange, process-loss recovery and rollback."""
import importlib.machinery
import importlib.util
import json
import pathlib
import signal
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
HELPER = ROOT / "bin/cornice-install-tree"


def tree(path, version):
    for directory in ("bin", "shell", "config"):
        (path / directory).mkdir(parents=True, exist_ok=True)
    (path / "shell/shell.qml").write_text("import QtQuick\nItem {}\n")
    for name in ("default", "session-services"):
        (path / "config" / (name + ".json")).write_text("{}")
    (path / "version").write_text(version)
    cli = path / "bin/cornice"
    cli.write_text("#!/bin/sh\nprintf '%s\\n' " + version + "\n")
    cli.chmod(0o755)


def call(operation, target, candidate=None, success=True, extra=()):
    args = [sys.executable, str(HELPER), operation, str(target)]
    if candidate is not None:
        args.append(str(candidate))
    args.extend(extra)
    result = subprocess.run(args, capture_output=True, text=True)
    assert (result.returncode == 0) == success, result.stderr
    return result


def interrupted(target, candidate, after, operation="activate"):
    code = """import importlib.machinery, importlib.util, os, sys
loader=importlib.machinery.SourceFileLoader('installer',sys.argv[1])
spec=importlib.util.spec_from_loader(loader.name,loader);module=importlib.util.module_from_spec(spec);loader.exec_module(module)
exchange=module.exchange;after=sys.argv[4]=='after'
def kill(left,right):
    if after: exchange(left,right)
    os.kill(os.getpid(),9)
module.exchange=kill
sys.argv=['installer',sys.argv[5],sys.argv[2]]+([sys.argv[3]] if sys.argv[5]=='activate' else [])
module.main()
"""
    result = subprocess.run([sys.executable, "-c", code, str(HELPER), str(target), str(candidate), "after" if after else "before", operation])
    assert result.returncode == -signal.SIGKILL


with tempfile.TemporaryDirectory(prefix="cornice-atomic-") as directory:
    base = pathlib.Path(directory)
    target = base / "prefix/share/cornice"
    tree(target, "old")
    first = target.parent / "generation-first"; tree(first, "first")
    call("activate", target, first)
    assert (target / "version").read_text() == "first" and (first / "version").read_text() == "old"
    call("rollback", target)
    assert (target / "version").read_text() == "old"
    assert subprocess.check_output([str(base / "prefix/bin/cornice")], text=True).strip() == "old"
    call("rollback", target)
    assert (target / "version").read_text() == "first"
    print("PASS atomic directory replacement and rollback preserve a working CLI")
    candidate = target.parent / "generation-killed-before"; tree(candidate, "before")
    interrupted(target, candidate, False)
    assert (target / "version").read_text() == "first" and (candidate / "version").read_text() == "before"
    call("rollback", target)
    assert (target / "version").read_text() == "old"
    print("PASS process loss before publication leaves current usable and previous rollback discoverable")
    call("rollback", target)
    for index in range(2):
        repeated = target.parent / ("generation-repeated-" + str(index)); tree(repeated, "unpublished")
        interrupted(target, repeated, False)
    call("rollback", target)
    assert (target / "version").read_text() == "old"
    print("PASS repeated interrupted upgrades keep the installed generation's rollback reachable")
    candidate = target.parent / "generation-killed-after"; tree(candidate, "after")
    interrupted(target, candidate, True)
    assert (target / "version").read_text() == "after" and (candidate / "version").read_text() == "old"
    call("rollback", target)
    assert (target / "version").read_text() == "old"
    print("PASS process loss after publication retains the old generation and can roll back")
    invalid = target.parent / "generation-invalid"; invalid.mkdir()
    call("activate", target, invalid, success=False)
    assert (target / "version").read_text() == "old"
    print("PASS incomplete candidate fails before touching current installation")
    desktop = target.parent / "generation-incomplete-desktop"; tree(desktop, "incomplete desktop")
    (desktop / "native/bin").mkdir(parents=True)
    (desktop / "native/bin/cornice-desktop-runtime").write_text("incomplete desktop")
    call("activate", target, desktop, success=False)
    assert (target / "version").read_text() == "old"
    print("PASS missing browser runtime rejects a desktop candidate before replacement")
    for name in ("cornice-desktop-runtime", "cornice-browser-runtime", "cornice-native-accessibility", "cornice-human-lock", "cornice-session-guard"):
        helper=desktop / "native/bin" / name
        helper.write_text("#!/bin/sh\nexit 0\n"); helper.chmod(0o755)
    missing_guard=call("activate",target,desktop,success=False)
    assert "cornice-application-guard" in missing_guard.stderr and (target / "version").read_text()=="old"
    print("PASS missing application lifetime guard rejects a desktop candidate before replacement")
    guard=desktop / "native/bin/cornice-application-guard"
    guard.write_text("#!/bin/sh\nexit 0\n"); guard.chmod(0o755)
    missing_endpoint=call("activate",target,desktop,success=False)
    assert "desktop-endpoint.mjs" in missing_endpoint.stderr and (target / "version").read_text()=="old"
    print("PASS missing shared endpoint module rejects a desktop candidate before replacement")
    candidate = target.parent / "generation-changed"; tree(candidate, "changed")
    call("activate", target, candidate)
    candidate.rename(target.parent / "moved-unrelated")
    tree(candidate, "unrelated")
    call("rollback", target, success=False)
    assert (target / "version").read_text() == "changed" and (candidate / "version").read_text() == "unrelated"
    print("PASS rollback refuses a replaced unrelated backup")
    source = base / "checkout"; tree(source, "checkout")
    linked = base / "linked/share/cornice"; linked.parent.mkdir(parents=True); linked.symlink_to(source)
    candidate = linked.parent / "generation-copy"; tree(candidate, "copy")
    call("activate", linked, candidate)
    assert (source / "version").read_text() == "checkout"
    call("rollback", linked)
    assert linked.is_symlink() and linked.resolve() == source
    print("PASS legacy symlink install can upgrade and rollback without modifying the checkout")

    for after in (False, True):
        restored = base / ("rollback-after" if after else "rollback-before") / "share/cornice"
        tree(restored, "old")
        helper = restored / "bin/cornice-restored-helper"
        helper.write_text("#!/bin/sh\necho restored\n"); helper.chmod(0o755)
        updated = restored.parent / "new-generation"; tree(updated, "new")
        new_helper = updated / "bin/cornice-new-helper"
        new_helper.write_text("#!/bin/sh\necho new\n"); new_helper.chmod(0o755)
        call("activate", restored, updated)
        bindir = restored.parent.parent / "bin"; bindir.mkdir()
        (bindir / "cornice-new-helper").symlink_to(restored / "bin/cornice-new-helper")
        interrupted(restored, updated, after, "rollback")
        assert (restored / "version").read_text() == ("old" if after else "new")
        result = call("rollback", restored)
        assert json.loads(result.stdout)["recovered"]
        assert (restored / "version").read_text() == "old"
        assert subprocess.check_output([str(bindir / "cornice-restored-helper")], text=True).strip() == "restored"
        assert not (bindir / "cornice-new-helper").is_symlink()
        print("PASS interrupted rollback " + ("after" if after else "before") + " exchange resumes to the restored tree and repairs helpers")
    guarded = base / "guarded/share/cornice"; tree(guarded, "old")
    installed = guarded.parent / "installed"; tree(installed, "installed")
    call("activate", guarded, installed)
    unpublished = guarded.parent / "unpublished"; tree(unpublished, "unpublished")
    interrupted(guarded, unpublished, False)
    result = call("rollback", guarded, extra=("--if-activated", str(unpublished)))
    assert json.loads(result.stdout)["rollback"] == "not-activated"
    assert (guarded / "version").read_text() == "installed"
    call("rollback", guarded)
    assert (guarded / "version").read_text() == "old"
    print("PASS a failed unpublished activation cannot undo the unrelated current installation")

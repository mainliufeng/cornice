"""Actual QtQuick screenshot export, cancellation and external Qt clipboard."""
from desktop_harness import *

try:
    initialize()
    build = BASE / "screenshot-controller-build"
    log = BASE / "screenshot-build.log"
    with log.open("w") as output:
        subprocess.run(["cmake", "-S", str(ROOT / "test/screenshot-controller"), "-B", str(build), "-DCMAKE_BUILD_TYPE=Release"], check=True, stdout=output, stderr=subprocess.STDOUT)
        subprocess.run(["cmake", "--build", str(build), "-j2"], check=True, stdout=output, stderr=subprocess.STDOUT)
    for source, name in (("virtual-keyboard-unstable-v1", "virtual-keyboard"), ("wlr-virtual-pointer-unstable-v1", "virtual-pointer")):
        for mode, extension in (("client-header", "h"), ("private-code", "c")):
            subprocess.run(["wayland-scanner", mode, str(FORK / "protocols" / (source + ".xml")), str(BASE / (name + "." + extension))], check=True)
    flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "wayland-client", "xkbcommon"], text=True).split()
    input_binary = BASE / "physical-input"
    subprocess.run(["cc", "-I" + str(BASE), str(FORK / "hyprtester/multiseat/input.c"), str(BASE / "virtual-keyboard.c"), str(BASE / "virtual-pointer.c"), "-o", str(input_binary), *flags], check=True)
    environment = dict(ENV, QT_QPA_PLATFORM="wayland", QSG_RHI_BACKEND="software", CORNICE_TEST_PHYSICAL_INPUT=str(input_binary))
    probe = start([str(build / "screenshot-controller-verify")], "screenshot-controller", env=environment)
    wait(lambda: probe.poll() is not None, timeout=90)
    result = (BASE / "screenshot-controller.log").read_text()
    print(result, flush=True)
    print("Final real primary focus:", human_state(), flush=True)
    assert probe.returncode == 0, (probe.returncode, result)
    assert "external Qt PNG clipboard PASS" in result, result
    record("actual QtQuick PNG export keeps GUI timers responsive, publishes only PNG, pastes through a separate Qt Wayland client, preserves private atomic files and rejects cancelled/replaced/destroyed exports")
finally:
    cleanup()

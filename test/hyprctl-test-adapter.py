"""Translate only fixture operations, without relaxing the actual assertions."""
import json
import re
import sys


def quote(value):
    return json.dumps(value, ensure_ascii=False)


def translate(args):
    mode, name, *values = args
    value = ' '.join(values)
    if mode == 'dispatch':
        if name == 'workspace':
            return 'dispatch', 'hl.dsp.focus({workspace=' + quote(value) + '})'
        if name == 'exec':
            return 'dispatch', 'hl.dsp.exec_cmd(' + quote(value) + ')'
        if name == 'focuswindow':
            return 'dispatch', 'hl.dsp.focus({window=' + quote(value) + '})'
        if name == 'closewindow':
            return 'dispatch', 'hl.dsp.window.close({window=' + quote(value) + '})'
        if name == 'fullscreenstate':
            internal, client = map(int, value.split())
            return 'dispatch', f'hl.dsp.window.fullscreen_state({{internal={internal},client={client},action="set"}})'
    elif mode == 'keyword':
        if name == 'monitor':
            output, monitor_mode, position, scale = value.split(',')
            float(scale)
            return 'eval', 'hl.monitor({output=' + quote(output) + ',mode=' + quote(monitor_mode) + ',position=' + quote(position) + ',scale=' + scale + '})'
        if name == 'cursor:no_warps':
            assert value in ('0', '1')
            return 'eval', 'hl.config({cursor={no_warps=' + ('true' if value == '1' else 'false') + '}})'
        if name == 'misc:on_focus_under_fullscreen':
            return 'eval', f'hl.config({{misc={{on_focus_under_fullscreen={int(value)}}}}})'
        if match := re.fullmatch(r'device\[(.+)\]:enabled', name):
            assert value in ('false', 'true')
            return 'eval', 'hl.device({name=' + quote(match[1]) + ',enabled=' + value + '})'
    raise ValueError(f'Unsupported fixture operation: {mode} {name}')


if __name__ == '__main__':
    print('\n'.join(translate(sys.argv[1:])))

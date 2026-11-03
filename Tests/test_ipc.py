"""Exercise the actual helper process and Unix protocol with simulated fans only."""
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import tempfile
import time

APP = Path(__file__).resolve().parents[1] / 'dist/Fengdu.app/Contents/MacOS/Fengdu'
with tempfile.TemporaryDirectory(prefix='fengdu-', dir='/private/tmp') as directory:
    process = subprocess.Popen([str(APP), '--helper-demo', directory, str(os.getuid())], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    path = directory + '/control.sock'
    try:
        for _ in range(80):
            if os.path.exists(path):
                break
            if process.poll() is not None:
                raise AssertionError(process.communicate())
            time.sleep(.1)
        assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
        def command(action, **fields):
            with socket.socket(socket.AF_UNIX) as client:
                client.settimeout(4)
                client.connect(path)
                client.sendall(json.dumps(dict(action=action, **fields)).encode()+b'\n')
                data = b''
                while b'\n' not in data:
                    data += client.recv(16384)
                return json.loads(data)
        state = command('status')['snapshot']
        assert state['demo'] and not state['controlled']
        assert 'error' in command('manual', targets={'0': -1, '1': 2500})
        state = command('manual', targets={'0': 3000, '1': 3200})['snapshot']
        assert state['controlled'] and state['fans'][0]['target'] == 3000
        # Keep the helper alive while intentionally allowing its control lease to expire.
        time.sleep(9)
        state = command('status')['snapshot']
        assert not state['controlled'] and all(f['mode'] == 0 for f in state['fans'])
        state = command('curve', low=50, high=80)['snapshot']
        assert state['controlled'] and state['mode'] == 'curve'
        state = command('system')['snapshot']
        assert not state['controlled']
        assert 'error' in command('write_any_smc_key')
        command('quit')
        process.wait(timeout=5)
        assert process.returncode == 0
        print('PASS: IPC permissions, validation, manual, lease expiry, curve, restore and clean exit (simulated hardware)')
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)

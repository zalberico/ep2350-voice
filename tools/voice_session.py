"""Read mic events or atomically queue speech for the current local voice turn."""
import argparse
import json
import time
import uuid
from pathlib import Path

root = Path.home() / 'Library/Application Support/EP2350Voice/bridge'
p = argparse.ArgumentParser()
p.add_argument('action', choices=['listen', 'speak', 'state'])
p.add_argument('--after', type=int, default=0)
p.add_argument('--timeout', type=float, default=45)
p.add_argument('--turn')
p.add_argument('--text')
args = p.parse_args()
if args.action == 'state':
    print((root / 'state.json').read_text())
elif args.action == 'speak':
    if not args.turn or not args.text:
        p.error('speak requires --turn and --text')
    payload = {'id': str(uuid.uuid4()), 'turnID': args.turn, 'text': args.text}
    temp = root / 'reply.tmp'
    temp.write_text(json.dumps(payload))
    temp.replace(root / 'reply.json')
    print(json.dumps({'queued': payload['id'], 'turnID': args.turn}))
else:
    until = time.monotonic() + min(args.timeout, 55)
    while True:
        path = root / 'events.jsonl'
        lines = path.read_text().splitlines() if path.exists() else []
        new = [json.loads(line) for line in lines[args.after:]]
        relevant = [e for e in new if e['type'] in ['utterance', 'interrupted', 'error', 'reply_rejected', 'stopped']]
        if relevant or time.monotonic() >= until:
            print(json.dumps({'cursor': len(lines), 'events': new}, indent=2))
            break
        time.sleep(.1)

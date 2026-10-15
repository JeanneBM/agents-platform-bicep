"""Map recorded CI graph transitions to monitor events, without inventing costs/tool calls."""
import json
from pathlib import Path


def ci_events(directory: Path):
    events = []
    for path in sorted(directory.glob('*/evidence.json')):
        state = json.loads(path.read_text())
        run_id = path.parent.name
        # Evidence has no transition timestamps: order below is reconstructed,
        # explicitly labelled, and must not be used for latency measurements.
        def emit(kind, **values):
            order = len(events) + 1
            events.append({'id': f'{run_id}-{order}', 'ts': float(order),
                           'agent': 'ci-repair', 'run_id': run_id, 'type': kind,
                           'attrs': {'source': 'ci_repair/evidence.json',
                                     'timeBasis': 'reconstructed-order',
                                     'tokenCostTelemetry': 'unavailable'}, **values})
        emit('run_started')
        for entry in state.get('history', []):
            emit('verification', status='ok' if entry['result'] == 'sufficient' else 'failed')
        if state['status'] in ('awaiting_approval', 'escalated', 'blocked'):
            emit('escalation', status=state['status'])
        emit('run_finished', status='escalated' if state['status'] in
             ('awaiting_approval', 'escalated', 'blocked') else 'success')
    if not events:
        raise ValueError('No real CI evidence available: refusing an empty monitor demonstration')
    return events

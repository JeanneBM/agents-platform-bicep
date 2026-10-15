"""Worker marker is owned by the worker and removed on orderly stop/failure."""
import json
import os
from pathlib import Path
import sys
from agent_monitor.live import atomic, watch

folder = Path(sys.argv[1])
config = json.loads((folder / 'sources.json').read_text())
marker = folder / 'running'
atomic(marker, {'pid': os.getpid(), 'instance': config['instance']})
try:
    watch(folder / 'sources.json', folder)
finally:
    marker.unlink(missing_ok=True)

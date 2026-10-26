"""Create the Finder drag-to-Applications layout without UI scripting."""
from pathlib import Path
import subprocess
import sys
import tempfile
import dmgbuild

app, destination = map(Path, sys.argv[1:])
if app.name != 'Zonal.app' or not app.is_dir() or destination.exists():
    raise SystemExit('Expected Zonal.app and a new DMG output path')
with tempfile.TemporaryDirectory(prefix='zonal-dmg-artwork-') as folder:
    background = Path(folder) / 'background.tiff'
    subprocess.run(['swift', str(Path(__file__).with_name('dmg-background.swift')), str(background)], check=True)
    dmgbuild.build_dmg(str(destination), 'Zonal', settings={
        'format': 'UDZO',
        'files': [str(app)],
        'symlinks': {'Applications': '/Applications'},
        'background': str(background),
        'window_rect': ((200, 160), (640, 400)),
        'icon_locations': {'Zonal.app': (170, 200), 'Applications': (470, 200)},
        'icon_size': 96, 'text_size': 14,
        'default_view': 'icon-view',
        'show_toolbar': False, 'show_sidebar': False, 'show_status_bar': False,
        'show_pathbar': False, 'show_tab_view': False,
        'include_icon_view_settings': True,
        'include_list_view_settings': False,
    })

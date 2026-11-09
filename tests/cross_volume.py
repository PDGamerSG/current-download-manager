"""Optional macOS disk-image test of exclusive media copying across volumes.

Creates and detaches a temporary 128 MiB APFS image; needs hdiutil availability.
"""
import json,os,plistlib,shutil,subprocess,sys,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"tests"))
from integration import Harness,wait_for
from media_service import decoded_video_hash
root=ROOT
with tempfile.TemporaryDirectory(prefix='current-cross-volume-') as temporary:
 folder=Path(temporary);image=folder/'test.dmg';device=None;fixture=None;h=Harness(folder)
 try:
  subprocess.run(['hdiutil','create','-size','128m','-fs','APFS','-volname','CurrentMediaTest','-quiet',str(image)],check=True,timeout=30,capture_output=True)
  attachment=plistlib.loads(subprocess.check_output(['hdiutil','attach','-nobrowse','-plist',str(image)],timeout=30))
  mount=next(x for x in attachment['system-entities'] if x.get('mount-point'))
  device=attachment['system-entities'][0]['dev-entry'];destination=Path(mount['mount-point'])/'downloads';destination.mkdir()
  ready=folder/'ready.json';fixture_folder=folder/'fixture';log=open(folder/'fixture.log','wb')
  fixture=subprocess.Popen([sys.executable,str(root/'tests/media_grabber_fixture.py'),'--directory',str(fixture_folder),'--ready',str(ready)],stdout=log,stderr=log)
  wait_for(ready.exists,20,'cross-volume fixture')
  h.start();url='http://127.0.0.1:%s/media/stream.m3u8'%json.loads(ready.read_text())['port']
  job=h.add(url,kind='media',filename='external.mp4',directory=str(destination),headers={'Cookie':'fixture=secret','Referer':'https://fixture.invalid/private'},connections=1)
  job=h.completed(job);target=destination/job['filename']
  ffmpeg=shutil.which('ffmpeg');assert decoded_video_hash(ffmpeg,target)==decoded_video_hash(ffmpeg,fixture_folder/'stream.m3u8')
  assert target.stat().st_dev!=(folder/'state').stat().st_dev
  h.command('delete-file',ids=[job['id']]);assert not target.exists()
  print(json.dumps({'crossVolumeMedia':'complete decoded frames verified','exclusiveCopy':'EXDEV path exercised','ownedFileDeletion':'verified','stateDevice':(folder/'state').stat().st_dev,'destinationDevice':destination.stat().st_dev},indent=2))
 finally:
  h.stop();h.log.close()
  if fixture:
   fixture.terminate();fixture.wait(timeout=8)
  if device:subprocess.run(['hdiutil','detach','-quiet',device],check=True,timeout=20,capture_output=True)

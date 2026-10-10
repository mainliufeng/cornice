# Screen recording

Click the video-camera button in the bar to record that screen. It changes to a red stop icon with elapsed time; click again to finish. Cornice displays the saved path. The MP4 is saved in `~/Videos/Cornice`, without audio. The visible desktop, including an observed or controlled secondary desktop, is recorded. A private desktop bar records its own output. Locking the session or removing the output stops recording.

The independent `cn.recording` plugin owns the UI, lifecycle and output selection. Its encoding backend is `wf-recorder`; it and `ffmpeg` are declared package dependencies installed together with Cornice by pacman. Cornice verifies the encoded video before reporting success. `install.sh` checks it before installing. No external recording UI is shown.

Change the destination in Cornice config:

```json
{"recording": {"directory": "~/Videos/Cornice"}}
```

CLI: `cornice ipc recording start <output-name>`, `cornice ipc recording stop`, and `cornice ipc recording status`. The bar supplies its actual output name; no output picker or terminal is needed.

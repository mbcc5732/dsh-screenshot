# Screenshot to chat

Adds a **Screenshot** button to the conversation composer's tool row. Clicking it switches the desktop straight into selection mode — no dimming, the screen keeps its brightness — then drag to select a region. The selection stays editable: move it, drag its handles to resize it, then confirm. The result is saved as a PNG, copied to the clipboard, and inserted into the current draft as an image attachment, ready to send together with your message.

The chrome follows the Doubao capture tool: a thin dark dashed outline, eight white round handles, a white rounded size chip just outside the top-left corner (`W * H`), and a white rounded action bar under the selection with a gradient primary pill.

## Usage

1. Open a conversation.
2. Click the scissor/camera **Screenshot** button in the composer tool row.
3. Drag over the area you want to capture. A single click on a window picks that window instead; hovering previews it with the dashed outline.
4. Adjust: drag inside the selection to move it, drag a corner or edge handle to resize it.
5. Confirm with `Enter`, a double-click inside the selection, or the **Insert into chat** pill. **Copy** puts the image on the clipboard without closing the selection (the label briefly reads "已复制"). **Cancel** and `Esc` discard it.
6. The screenshot appears as an attachment in the composer. Type your question and send.

## Notes

- Windows only: capture uses Windows PowerShell and .NET screen APIs.
- Multi-monitor: drag across monitors to capture any visible region; the selection overlay spans the whole virtual desktop, and coordinates are per-monitor DPI aware, so scaled displays are captured at their native pixels.
- The latest image is also copied to the clipboard, so you can paste it elsewhere.
- The PNG is written to the system temporary directory (`dsh-screenshot-tool`) only to hand its bytes over, then deleted; the clipboard keeps the copy.
- A resident PowerShell helper is preheated when the plugin loads (about 60–80MB private memory) so the overlay appears in roughly 130–220ms instead of restarting a process per click. It exits with the host, and any overlay it left open closes within a second if the host disappears.
- To read the image content, the active model must support image input.

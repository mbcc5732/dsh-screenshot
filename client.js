window.__ModuleLoader__.load({
  id: '@local/dsh-screenshot',
  factory(require) {
    const React = require('react')
    const h = React.createElement
    const CAPTURE_ROUTE = '/api/dsh-screenshot/capture'
    // The host kills its PowerShell at 130s; failing here first keeps the button
    // from sitting disabled through a dead request.
    const CAPTURE_TIMEOUT_MS = 140000

    function base64ToFile(base64, name) {
      const binary = atob(base64)
      const bytes = new Uint8Array(binary.length)
      for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i)
      return new File([bytes], name, { type: 'image/png' })
    }

    function ScreenshotButton({ inputActions, sessionId, conversation, t }) {
      const [busy, setBusy] = React.useState(false)

      const onClick = async () => {
        if (busy) return
        setBusy(true)
        try {
          const response = await fetch(CAPTURE_ROUTE, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: '{}',
            signal: typeof AbortSignal.timeout === 'function'
              ? AbortSignal.timeout(CAPTURE_TIMEOUT_MS)
              : undefined,
          })
          const result = await response.json().catch(() => null)
          if (!response.ok || !result || !result.ok) {
            throw new Error(result && result.error ? result.error : `HTTP ${response.status}`)
          }
          // Cancelling is a normal end: the overlay closed on Esc, so nothing is
          // reported. Silence is the whole point of this button.
          if (result.cancelled) return
          const file = base64ToFile(result.data, result.name || 'screenshot.png')
          const drafts = conversation.createDrafts(sessionId, [file], true)
          if (!inputActions.addAttachments(drafts.map((draft) => draft.id))) {
            conversation.releaseDraftAttachments(drafts)
            throw new Error('could not attach screenshot')
          }
        } catch (error) {
          // No toast on screen; failures stay diagnosable in the console.
          const message = error && error.message ? error.message : String(error)
          console.error('[dsh-screenshot]', message)
        } finally {
          setBusy(false)
        }
      }

      return h('span', {
        style: { position: 'relative', display: 'inline-flex', alignItems: 'center' },
        title: t('button'),
      },
        h('button', {
          type: 'button',
          onClick,
          // Button presses steal focus from the draft editor; suppressing the
          // default at mousedown keeps the caret where the user left it, which
          // is what every native composer control does.
          onMouseDown: (event) => { event.preventDefault() },
          disabled: busy,
          'aria-label': t('button'),
          style: {
            display: 'inline-flex',
            alignItems: 'center',
            justifyContent: 'center',
            width: 30,
            height: 30,
            padding: 0,
            border: '1px solid transparent',
            borderRadius: 6,
            background: 'transparent',
            color: 'var(--dsw-alias-label-secondary, currentColor)',
            cursor: busy ? 'default' : 'pointer',
            opacity: busy ? 0.5 : 1,
          },
        },
          h('svg', {
            viewBox: '0 0 24 24', width: 18, height: 18,
            fill: 'none', stroke: '#3b7dd8', 'stroke-width': 2,
            'stroke-linecap': 'round', 'stroke-linejoin': 'round',
            'aria-hidden': true,
          },
            // Camera: rounded body, a viewfinder hump on the top edge, thick lens
            // ring - one path so the hump merges into the outline.
            h('path', { d: 'M6.1 8.5H9Q12 5.1 15 8.5H17.9A2.5 2.5 0 0 1 20.4 11V17.9A2.5 2.5 0 0 1 17.9 20.4H6.1A2.5 2.5 0 0 1 3.6 17.9V11A2.5 2.5 0 0 1 6.1 8.5Z' }),
            h('circle', { cx: 12, cy: 14.3, r: 3.5 }),
          )
        ),
      )
    }

    return {
      inject: ['slots', 'conversation'],
      apply(ctx) {
        const conversation = ctx.get('conversation')
        const zh = typeof navigator !== 'undefined' && /^zh\b/i.test(navigator.language || '')
        const dicts = {
          en: { button: 'Screenshot' },
          zh: { button: '截屏' },
        }
        const tr = (key) => (zh ? dicts.zh : dicts.en)[key] || key

        ctx.slots.inject('conversation.input.left', () => ctx.slots.register({
          name: 'conversation.input.left',
          id: 'dsh-screenshot',
          order: 10,
          inject: (sessionId) => ({ sessionId }),
        }, (props) => h(ScreenshotButton, {
          inputActions: props.inputActions,
          sessionId: props.sessionId,
          conversation,
          t: tr,
        })))
      },
    }
  },
})

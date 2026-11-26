window.__ModuleLoader__.load({
  id: '@local/dsh-screenshot',
  factory(require) {
    const React = require('react')
    const h = React.createElement
    const CAPTURE_ROUTE = '/api/dsh-screenshot/capture'
    // The host kills its PowerShell at 130s; failing here first keeps the button
    // from sitting disabled through a dead request.
    const CAPTURE_TIMEOUT_MS = 140000

    // Where the entry lives: 'menu' = only in the composer "+" menu (Doubao
    // style), 'toolbar' = only the inline button, 'both' = both places.
    const PLACEMENT_KEY = 'dsh-screenshot:placement'
    const PLACEMENTS = ['menu', 'toolbar', 'both']
    const PLACEMENT_FALLBACK = 'both'
    const placementListeners = new Set()
    // sessionId -> capture callback, published by the mounted composer button so
    // the menu row can drive the exact same flow (attachments need the slot's
    // inputActions and the session-bound conversation).
    const captureHandlers = new Map()

    function readPlacement() {
      try {
        const stored = window.localStorage.getItem(PLACEMENT_KEY)
        return PLACEMENTS.indexOf(stored) === -1 ? PLACEMENT_FALLBACK : stored
      } catch (error) {
        return PLACEMENT_FALLBACK
      }
    }

    let placement = readPlacement()

    function setPlacement(next) {
      if (PLACEMENTS.indexOf(next) === -1 || next === placement) return
      placement = next
      try {
        window.localStorage.setItem(PLACEMENT_KEY, next)
      } catch (error) {
        /* storage disabled: the choice still applies for this session */
      }
      for (const listener of placementListeners) listener(next)
    }

    function subscribePlacement(listener) {
      placementListeners.add(listener)
      listener(placement)
      return () => { placementListeners.delete(listener) }
    }

    function base64ToFile(base64, name) {
      const binary = atob(base64)
      const bytes = new Uint8Array(binary.length)
      for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i)
      return new File([bytes], name, { type: 'image/png' })
    }

    // The host appends these to %TEMP%\dsh-screenshot-client.log: a menu entry
    // that fails to register is invisible on screen, so it needs a paper trail.
    function diag(payload) {
      try {
        fetch('/api/dsh-screenshot/diag', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(payload),
        }).catch(() => {})
      } catch (error) { /* diagnostics never break the plugin */ }
    }

    // Camera glyph: rounded body, a viewfinder hump on the top edge, thick lens
    // ring - one path so the hump merges into the outline. Shared by the
    // composer button and the two menu rows.
    function CameraIcon(props) {
      const size = (props && props.size) || 16
      return h('svg', {
        viewBox: '0 0 24 24', width: size, height: size,
        fill: 'none', stroke: '#3b7dd8', 'stroke-width': 2,
        'stroke-linecap': 'round', 'stroke-linejoin': 'round',
        'aria-hidden': true,
      },
        h('path', { d: 'M6.1 8.5H9Q12 5.1 15 8.5H17.9A2.5 2.5 0 0 1 20.4 11V17.9A2.5 2.5 0 0 1 17.9 20.4H6.1A2.5 2.5 0 0 1 3.6 17.9V11A2.5 2.5 0 0 1 6.1 8.5Z' }),
        h('circle', { cx: 12, cy: 14.3, r: 3.5 }),
      )
    }

    function ScreenshotButton({ inputActions, sessionId, conversation, t }) {
      const [busy, setBusy] = React.useState(false)
      const [mode, setMode] = React.useState(placement)

      React.useEffect(() => subscribePlacement(setMode), [])

      const onClick = React.useCallback(async () => {
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
      }, [busy, conversation, inputActions, sessionId])

      // Published while mounted - also while hidden in "menu" mode - so the
      // menu row never depends on the button being visible.
      React.useEffect(() => {
        captureHandlers.set(sessionId, onClick)
        return () => {
          if (captureHandlers.get(sessionId) === onClick) captureHandlers.delete(sessionId)
        }
      }, [onClick, sessionId])

      return h('span', {
        style: {
          position: 'relative',
          display: mode === 'menu' ? 'none' : 'inline-flex',
          alignItems: 'center',
        },
        title: t('button'),
      },
        h('button', {
          type: 'button',
          onClick,
          'data-dsh-screenshot': '',
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
        }, h(CameraIcon, { size: 18 }))
      )
    }

    return {
      inject: ['slots', 'conversation', 'commandUi'],
      apply(ctx) {
        const conversation = ctx.get('conversation')
        const commandUi = ctx.get('commandUi')
        const zh = typeof navigator !== 'undefined' && /^zh\b/i.test(navigator.language || '')
        const dicts = {
          en: {
            button: 'Screenshot',
            row: 'Screenshot',
            rowDesc: 'Select a screen region and attach it as an image',
            placement: 'Screenshot entry',
            placementDesc: 'Choose where the screenshot entry lives',
            menu: '“+” menu only',
            menuDesc: 'One row inside the composer + menu, like Doubao',
            toolbar: 'Toolbar button only',
            toolbarDesc: 'The camera button left of the composer',
            both: 'Both places',
            bothDesc: 'Button plus the + menu row',
          },
          zh: {
            button: '截屏',
            row: '截图',
            rowDesc: '框选屏幕区域，作为图片附件插入',
            placement: '截图入口',
            placementDesc: '选择截图入口放在哪里',
            menu: '仅“+”菜单',
            menuDesc: '收进输入框 + 菜单里，和豆包一样',
            toolbar: '仅工具栏按钮',
            toolbarDesc: '输入框左侧的相机按钮',
            both: '两处都放',
            bothDesc: '按钮 + “+”菜单里各一个',
          },
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

        diag({
          stage: 'apply',
          hasCommandUi: commandUi !== undefined,
          hasSlots: ctx.get('slots') !== undefined,
          language: zh ? 'zh' : 'en',
        })

        if (commandUi === undefined) {
          console.error('[dsh-screenshot] commandUi unavailable: the + menu entry is off')
          return
        }

        try {
          ctx.effect(() => commandUi.register({
            name: 'screenshot',
            label: () => tr('row'),
            description: () => tr('rowDesc'),
            icon: CameraIcon,
            available: () => true,
            ui: {
              kind: 'action',
              run(session) {
                const key = session === undefined || session === null ? '' : String(session.sessionId)
                const exact = captureHandlers.get(key)
                if (exact !== undefined) {
                  exact()
                  return
                }
                // The mounted composer button owns the flow for the active session.
                const element = document.querySelector('[data-dsh-screenshot]')
                if (element) {
                  element.click()
                  return
                }
                const any = captureHandlers.values().next().value
                if (any !== undefined) any()
              },
            },
          }))

          ctx.effect(() => commandUi.register({
            name: 'screenshot-placement',
            label: () => tr('placement'),
            description: () => tr('placementDesc'),
            icon: CameraIcon,
            available: () => true,
            ui: {
              kind: 'popupSelect',
              async options() {
                const current = placement
                return PLACEMENTS.map((id) => ({
                  id,
                  label: tr(id),
                  detail: tr(`${id}Desc`),
                  active: id === current,
                }))
              },
              onSelect(option) {
                setPlacement(option.id)
              },
            },
          }))
        } catch (error) {
          diag({
            stage: 'register-failed',
            error: String((error && error.stack) || error),
          })
          console.error('[dsh-screenshot] could not register the menu entries', error)
        }
      },
    }
  },
})

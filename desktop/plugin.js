/**
 * session-lock — desktop half.
 *
 * Statusbar chip ("Locks N" / "锁 N") → a dialog listing every active-session
 * lease in the registry (session, surface, pid, whether the owner process is
 * still alive) with buttons to drop one, drop only the dead ones, or drop
 * everything.
 *
 * The real work happens in the Python half:
 *   <hermes home>/plugins/session-lock/dashboard/plugin_api.py
 * reached through ctx.rest('/leases') and ctx.rest('/release').
 *
 * Releasing a lease whose owner is STILL ALIVE lets two clients write one chat
 * at once — those paths confirm first, and say so.
 *
 * Strings live in MESSAGES (en + zh) and follow the app's display.language,
 * which is the OS language when the user has not picked one.
 */

import {
  Button,
  ConfirmDialog,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  cn,
  haptic,
  host,
  usePluginI18n,
  useQuery,
  useQueryClient
} from '@hermes/plugin-sdk'
import { Fragment, useState } from 'react'
import { jsx, jsxs } from 'react/jsx-runtime'

const ID = 'session-lock'
const QUERY_KEY = [ID, 'leases']
let ctxRef = null

const MESSAGES = {
  en: {
    chip: 'Locks',
    chipTip: 'Session locks: view and release',
    title: 'Session locks',
    intro:
      'The "This chat is open somewhere else" refusal comes from an entry in this list. Remove one and any device or platform can take that session again.',
    loading: 'Loading…',
    empty: 'No session locks right now',
    untitled: 'Untitled session',
    sessionId: id => `ID ${id}`,
    from: surface => `from ${surface}`,
    pid: pid => `pid ${pid}`,
    ageSeconds: n => `${n}s ago`,
    ageMinutes: n => `${n}m ago`,
    ageHours: n => `${n}h ago`,
    ageDays: n => `${n}d ago`,
    ageUnknown: 'never updated',
    alive: 'owner alive',
    dead: 'owner gone (stale)',
    unknown: 'liveness unknown',
    release: 'Release',
    releaseDead: 'Clear dead only',
    refresh: 'Refresh',
    releaseCurrent: 'Release this chat',
    releaseAll: 'Release all…',
    backendDown: error => `Backend unavailable: ${error}`,
    released: n => `Released ${n} session lock${n === 1 ? '' : 's'}`,
    nothingToRelease: 'Nothing to release',
    releaseFailed: error => `Release failed: ${error}`,
    confirmAllTitle: 'Release every session lock?',
    confirmAllBody:
      'This deletes every lease, whichever device or platform created it. If an owner process is still alive (another computer has this chat open, for example), both clients can write the same conversation afterwards.',
    confirmAllLabel: 'Release all',
    confirmAliveTitle: name => `Release "${name}"?`,
    confirmAliveBody: (name, pid, surface) =>
      `"${name}" (pid ${pid}, ${surface}) is still running and using this session. After releasing, both clients may write to the same conversation.`,
    confirmDeadTitle: name => `Release "${name}"`,
    confirmDeadBody: (name, pid) =>
      `"${name}" (pid ${pid}) is gone, so this lease is stale - releasing it is safe.`,
    confirmLabel: 'Release'
  },
  zh: {
    chip: '锁',
    chipTip: '会话锁：查看 / 释放',
    title: '会话锁',
    intro:
      '“This chat is open somewhere else” 就是这张表里的某条记录挡住的。删掉之后，任何设备或平台都能重新占用该会话。',
    loading: '读取中…',
    empty: '当前没有任何会话锁',
    untitled: '未命名会话',
    sessionId: id => `ID ${id}`,
    from: surface => `来源 ${surface}`,
    pid: pid => `pid ${pid}`,
    ageSeconds: n => `${n} 秒前`,
    ageMinutes: n => `${n} 分钟前`,
    ageHours: n => `${n} 小时前`,
    ageDays: n => `${n} 天前`,
    ageUnknown: '从未更新',
    alive: '持有者活着',
    dead: '持有者已退出（残留）',
    unknown: '存活未知',
    release: '释放',
    releaseDead: '只清死锁',
    refresh: '刷新',
    releaseCurrent: '释放当前会话',
    releaseAll: '释放全部…',
    backendDown: error => `后端不可用：${error}`,
    released: n => `已释放 ${n} 个会话锁`,
    nothingToRelease: '没有可释放的会话锁',
    releaseFailed: error => `释放失败：${error}`,
    confirmAllTitle: '释放全部会话锁？',
    confirmAllBody:
      '会把当前所有会话的锁全部删掉，不管它是哪个设备、哪个平台留下的。如果某个锁的持有进程还活着（比如另一台电脑正开着这个会话），两边可能同时写同一段对话。',
    confirmAllLabel: '全部释放',
    confirmAliveTitle: name => `释放「${name}」？`,
    confirmAliveBody: (name, pid, surface) =>
      `「${name}」（pid ${pid}，来源 ${surface}）还活着并且正在使用这个会话。释放后这两个客户端可能同时往同一段对话里写。`,
    confirmDeadTitle: name => `释放「${name}」`,
    confirmDeadBody: (name, pid) =>
      `「${name}」（pid ${pid}）的持有者已经不在了，这是残留的锁，释放是安全的。`,
    confirmLabel: '释放'
  }
}

function fmtAge(seconds, t) {
  if (seconds == null) return t('ageUnknown')
  if (seconds < 90) return t('ageSeconds', Math.round(seconds))
  if (seconds < 5400) return t('ageMinutes', Math.round(seconds / 60))
  if (seconds < 172800) return t('ageHours', Number((seconds / 3600).toFixed(1)))
  return t('ageDays', Number((seconds / 86400).toFixed(1)))
}

function liveness(entry, t) {
  if (entry.alive === true) return { label: t('alive'), tone: 'text-(--ui-text-secondary)' }
  if (entry.alive === false) return { label: t('dead'), tone: 'text-destructive' }
  return { label: t('unknown'), tone: 'text-(--ui-text-tertiary)' }
}

function LeaseRow({ entry, onRelease, sessionTitles }) {
  const t = usePluginI18n(ID)
  const state = liveness(entry, t)
  const fallbackTitle = ((sessionTitles || {})[entry.session_id] || '').trim()
  const title = (entry.title || fallbackTitle || '').trim()
  const hasTitle = title.length > 0
  const primary = hasTitle ? title : entry.session_id || t('untitled')
  return jsxs('div', {
    className: 'flex items-center gap-3 border-b border-(--ui-stroke-secondary) px-1 py-2 last:border-b-0',
    children: [
      jsxs('div', {
        className: 'flex min-w-0 flex-1 flex-col gap-0.5',
        children: [
          jsx('div', {
            className: 'truncate text-xs font-medium text-foreground',
            children: primary
          }),
          jsxs('div', {
            className: 'flex flex-wrap items-center gap-x-3 text-[0.6875rem] text-(--ui-text-tertiary)',
            children: [
              ...(hasTitle
                ? [
                    jsx('span', {
                      className: 'truncate font-mono',
                      children: t('sessionId', entry.session_id)
                    })
                  ]
                : []),
              jsx('span', { children: t('from', entry.surface || '?') }),
              jsx('span', { children: t('pid', entry.pid ?? '?') }),
              jsx('span', { children: fmtAge(entry.age_seconds, t) })
            ]
          }),
          jsx('div', { className: cn('text-[0.6875rem]', state.tone), children: state.label })
        ]
      }),
      jsx(Button, { size: 'sm', variant: 'outline', onClick: () => onRelease(entry), children: t('release') })
    ]
  })
}

function LockChip() {
  const t = usePluginI18n(ID)
  const [open, setOpen] = useState(false)
  const [pending, setPending] = useState(null)
  const [error, setError] = useState(null)
  const query = useQuery({
    queryKey: QUERY_KEY,
    queryFn: () => ctxRef.rest('/leases'),
    refetchInterval: 15000,
    staleTime: 4000
  })
  // The running gateway may not have reloaded the Python half yet (it needs a
  // desktop restart). Resolve names through the gateway's own session list so
  // the dialog shows titles immediately; ids remain the fallback.
  const sessionsQuery = useQuery({
    queryKey: [ID, 'session-titles'],
    queryFn: async () => {
      const res = await host.request('session.list', { limit: 200, include_hidden: true })
      const payload = res && res.sessions ? res : (res && res.result) || {}
      const map = {}
      for (const row of payload.sessions || []) {
        const title = (row.title || '').trim()
        const id = row.id || row.session_id
        if (id && title) map[id] = title
        if (row._lineage_root_id && title) map[row._lineage_root_id] = title
      }
      return map
    },
    refetchInterval: 60000,
    staleTime: 30000
  })
  const sessionTitles = sessionsQuery.data || {}
  const queryClient = useQueryClient()

  const entries = query.data?.entries || []
  const count = query.data?.count || 0

  const refresh = () => queryClient.invalidateQueries({ queryKey: QUERY_KEY })

  const runRelease = async (payload) => {
    setError(null)
    try {
      const res = await ctxRef.rest('/release', { method: 'POST', body: payload })
      host.notify({
        kind: res.removed.length ? 'success' : 'info',
        message: res.removed.length ? t('released', res.removed.length) : t('nothingToRelease')
      })
      setPending(null)
      setOpen(false)
      refresh()
    } catch (err) {
      const text = String((err && err.message) || err)
      setError(text)
      host.notify({ kind: 'error', message: t('releaseFailed', text) })
    }
  }

  const askOne = (entry) => {
    const alive = entry.alive === true
    const name = (entry.title || (sessionTitles[entry.session_id] || '')).trim()
      || entry.session_id || t('untitled')
    setPending({
      payload: { scope: 'session', session_id: entry.session_id, confirm: true },
      title: alive ? t('confirmAliveTitle', name) : t('confirmDeadTitle', name),
      description: alive
        ? t('confirmAliveBody', name, entry.pid, entry.surface || '?')
        : t('confirmDeadBody', name, entry.pid ?? '?'),
      label: t('confirmLabel')
    })
  }

  const askAll = () =>
    setPending({
      payload: { scope: 'all', confirm: true },
      title: t('confirmAllTitle'),
      description: t('confirmAllBody'),
      label: t('confirmAllLabel')
    })

  const releaseCurrent = () => {
    const active = host.state.activeSessionId.get()
    if (!active) return
    const mine = entries.find((entry) => entry.session_id === active)
    if (mine) askOne(mine)
    else runRelease({ scope: 'session', session_id: active, confirm: true })
  }

  const chip = jsx('button', {
    type: 'button',
    title: t('chipTip'),
    className: cn(
      'inline-flex h-full items-center gap-1 px-1.5 text-[0.6875rem] transition-colors',
      'text-(--ui-text-tertiary) hover:bg-(--chrome-action-hover) hover:text-foreground'
    ),
    onClick: () => {
      haptic('tap')
      setOpen(true)
    },
    children: jsxs('span', {
      className: 'inline-flex items-center gap-1',
      children: [
        jsx('span', { children: t('chip') }),
        jsx('span', { className: 'tabular-nums', children: String(count) })
      ]
    })
  })

  const dialog = jsx(Dialog, {
    open,
    onOpenChange: (next) => {
      setOpen(next)
      if (next) refresh()
    },
    children: jsx(DialogContent, {
      className: 'max-w-xl',
      children: jsxs('div', {
        className: 'flex flex-col gap-3',
        children: [
          jsx(DialogHeader, {
            children: jsxs('div', {
              className: 'flex flex-col gap-1',
              children: [
                jsx(DialogTitle, { children: t('title') }),
                jsx(DialogDescription, { children: t('intro') })
              ]
            })
          }),
          query.isLoading
            ? jsx('div', { className: 'py-6 text-center text-xs text-(--ui-text-tertiary)', children: t('loading') })
            : entries.length === 0
              ? jsx('div', {
                  className: 'py-6 text-center text-xs text-(--ui-text-tertiary)',
                  children: t('empty')
                })
              : jsx('div', {
                  className: 'max-h-[45vh] overflow-y-auto',
                  children: entries.map((entry) =>
                    jsx(LeaseRow, { entry, onRelease: askOne, sessionTitles }, entry.lease_id || entry.session_id)
                  )
                }),
          error
            ? jsx('div', {
                className: 'rounded-md bg-destructive/10 px-2 py-1.5 text-xs text-destructive',
                children: error
              })
            : null,
          query.error
            ? jsx('div', {
                className: 'rounded-md bg-destructive/10 px-2 py-1.5 text-xs text-destructive',
                children: t('backendDown', String(query.error.message || query.error))
              })
            : null,
          jsx(DialogFooter, {
            className: 'flex flex-wrap items-center gap-2',
            children: [
              jsx(Button, {
                size: 'sm',
                variant: 'outline',
                onClick: () => runRelease({ scope: 'dead', confirm: false }),
                children: t('releaseDead')
              }),
              jsx(Button, { size: 'sm', variant: 'outline', onClick: () => refresh(), children: t('refresh') }),
              jsx('div', { className: 'flex-1' }),
              jsx(Button, {
                size: 'sm',
                variant: 'outline',
                disabled: !host.state.activeSessionId.get(),
                onClick: releaseCurrent,
                children: t('releaseCurrent')
              }),
              jsx(Button, { size: 'sm', variant: 'destructive', onClick: askAll, children: t('releaseAll') })
            ]
          })
        ]
      })
    })
  })

  const confirm = jsx(ConfirmDialog, {
    open: Boolean(pending),
    onClose: () => setPending(null),
    onConfirm: async () => {
      if (pending) await runRelease(pending.payload)
    },
    title: pending ? pending.title : '',
    description: pending ? pending.description : '',
    confirmLabel: pending ? pending.label : t('confirmLabel'),
    destructive: true
  })

  return jsxs(Fragment, { children: [chip, dialog, confirm] })
}

export default {
  id: ID,
  name: 'Session Lock',
  register(ctx) {
    ctxRef = ctx
    ctx.i18n.register(MESSAGES)
    ctx.register({ id: 'chip', area: 'statusBar.right', order: 155, render: () => jsx(LockChip, {}) })
  }
}

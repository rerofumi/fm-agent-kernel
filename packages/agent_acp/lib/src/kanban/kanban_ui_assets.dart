/// Self-contained embedded HTML/CSS/Vanilla ES2022 JS for the local Kanban GUI.
/// Strictly contains ZERO external HTTP/HTTPS resource references ([D-323] §4.1).
const String kanbanIndexHtml = r'''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <meta name="csrf-token" content="__CSRF_TOKEN__" />
  <title>FM Agent OS — Kanban</title>
  <style>
    :root {
      --bg: #0f172a;
      --surface: #1e293b;
      --surface-2: #273449;
      --border: #334155;
      --text: #f1f5f9;
      --muted: #94a3b8;
      --accent: #38bdf8;
      --ok: #22c55e;
      --warn: #f59e0b;
      --danger: #ef4444;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
      background: var(--bg);
      color: var(--text);
      min-height: 100vh;
      display: flex;
      flex-direction: column;
    }
    header.topbar {
      display: flex;
      flex-wrap: wrap;
      align-items: center;
      gap: 12px;
      padding: 10px 16px;
      background: var(--surface);
      border-bottom: 1px solid var(--border);
    }
    .brand { font-weight: 700; font-size: 15px; color: var(--accent); }
    .meta-pill {
      font-size: 12px;
      padding: 3px 8px;
      border-radius: 999px;
      background: var(--surface-2);
      border: 1px solid var(--border);
      color: var(--muted);
    }
    .spacer { flex: 1; }
    select, input, textarea, button {
      font-family: inherit;
      font-size: 13px;
      border-radius: 6px;
      border: 1px solid var(--border);
      background: var(--surface-2);
      color: var(--text);
      padding: 6px 10px;
    }
    button { cursor: pointer; font-weight: 600; }
    button.primary { background: #0284c7; border-color: #0369a1; }
    button.warn { background: #b45309; border-color: #92400e; }
    button.danger { background: #b91c1c; border-color: #991b1b; }
    button.ok { background: #15803d; border-color: #166534; }
    button:disabled { opacity: 0.5; cursor: not-allowed; }
    main.board {
      flex: 1;
      display: grid;
      grid-template-columns: repeat(5, minmax(230px, 1fr));
      gap: 12px;
      padding: 14px;
      overflow-x: auto;
    }
    .lane {
      background: var(--surface);
      border: 1px solid var(--border);
      border-radius: 10px;
      display: flex;
      flex-direction: column;
      min-height: 420px;
    }
    .lane-header {
      padding: 10px 12px;
      font-weight: 700;
      font-size: 13px;
      border-bottom: 1px solid var(--border);
      display: flex;
      justify-content: space-between;
      align-items: center;
    }
    .lane-body {
      padding: 10px;
      display: flex;
      flex-direction: column;
      gap: 10px;
      flex: 1;
    }
    .card {
      background: var(--surface-2);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 10px;
      display: flex;
      flex-direction: column;
      gap: 6px;
    }
    .card-title { font-weight: 700; font-size: 14px; }
    .card-sub { font-size: 12px; color: var(--muted); word-break: break-word; }
    .badge-row { display: flex; flex-wrap: wrap; gap: 4px; }
    .badge {
      font-size: 11px;
      padding: 2px 6px;
      border-radius: 4px;
      background: var(--surface);
      border: 1px solid var(--border);
      color: var(--accent);
    }
    .badge.conflict { color: var(--danger); border-color: var(--danger); }
    .badge.queued { color: var(--warn); border-color: var(--warn); }
    .badge.subprocess { color: var(--warn); border-color: var(--warn); }
    .perm-banner {
      display: none;
      flex-direction: column;
      gap: 8px;
      padding: 10px 14px 0 14px;
    }
    .perm-banner.visible { display: flex; }
    .perm-box {
      background: var(--surface);
      border: 1px solid var(--warn);
      border-radius: 8px;
      padding: 8px 10px;
      display: flex;
      flex-direction: column;
      gap: 6px;
      margin-top: 4px;
    }
    .perm-title { font-weight: 700; font-size: 13px; color: var(--warn); }
    .perm-reason { font-size: 12px; color: var(--text); word-break: break-word; }
    .card-actions { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 4px; }
    .stream-box {
      font-family: ui-monospace, SFMono-Regular, Consolas, monospace;
      font-size: 11px;
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: 6px;
      padding: 6px;
      max-height: 110px;
      overflow-y: auto;
      white-space: pre-wrap;
    }
    dialog {
      background: var(--surface);
      color: var(--text);
      border: 1px solid var(--border);
      border-radius: 10px;
      max-width: 640px;
      width: 92vw;
      padding: 16px;
    }
    dialog::backdrop { background: rgba(0, 0, 0, 0.65); }
    .form-row { display: flex; flex-direction: column; gap: 4px; margin-bottom: 10px; }
    .diff-pre {
      background: var(--bg);
      border: 1px solid var(--border);
      padding: 10px;
      border-radius: 6px;
      max-height: 300px;
      overflow: auto;
      font-family: ui-monospace, Consolas, monospace;
      font-size: 12px;
      white-space: pre-wrap;
    }
  </style>
</head>
<body>
  <header class="topbar">
    <span class="brand">FM Agent OS Kanban</span>
    <span id="repo-pill" class="meta-pill">cwd: -</span>
    <span id="change-pill" class="meta-pill">change: -</span>
    <span id="ctx-pill" class="meta-pill">ctx/swap: 0</span>
    <label>Model:
      <select id="session-model"></select>
    </label>
    <div class="spacer"></div>
    <button id="btn-new-card" class="primary">+ New Card</button>
    <button id="btn-global-stop" class="warn">Pause All</button>
    <button id="btn-global-cont" class="ok">Resume All</button>
    <button id="btn-shutdown" class="danger">Shutdown</button>
  </header>

  <section id="global-permissions" class="perm-banner"></section>

  <main class="board" id="board">
    <section class="lane" data-lane="todo">
      <div class="lane-header"><span>Todo</span><span id="count-todo">0</span></div>
      <div class="lane-body" id="lane-todo"></div>
    </section>
    <section class="lane" data-lane="running">
      <div class="lane-header"><span>Running</span><span id="count-running">0</span></div>
      <div class="lane-body" id="lane-running"></div>
    </section>
    <section class="lane" data-lane="paused">
      <div class="lane-header"><span>Paused</span><span id="count-paused">0</span></div>
      <div class="lane-body" id="lane-paused"></div>
    </section>
    <section class="lane" data-lane="review">
      <div class="lane-header"><span>Conflict / Review</span><span id="count-review">0</span></div>
      <div class="lane-body" id="lane-review"></div>
    </section>
    <section class="lane" data-lane="done">
      <div class="lane-header"><span>Done</span><span id="count-done">0</span></div>
      <div class="lane-body" id="lane-done"></div>
    </section>
  </main>

  <dialog id="new-card-dialog">
    <h3>Create Kanban Card</h3>
    <div class="form-row">
      <label>Title</label>
      <input id="nc-title" type="text" placeholder="Task title" />
    </div>
    <div class="form-row">
      <label>Prompt / Instruction</label>
      <textarea id="nc-prompt" rows="3" placeholder="What should the agent do?"></textarea>
    </div>
    <div class="form-row">
      <label>Execution Mode</label>
      <select id="nc-mode">
        <option value="single">Single Agent</option>
        <option value="parallel_team">Parallel WorkspaceWorker Team</option>
      </select>
    </div>
    <div class="form-row">
      <label>Stacked On (Parent Task ID, optional)</label>
      <select id="nc-parent"><option value="">(None — Root Task)</option></select>
    </div>
    <div class="form-row">
      <label>Model (optional override)</label>
      <select id="nc-model"><option value="">(Session Default)</option></select>
    </div>
    <div class="card-actions">
      <button id="nc-create" class="primary">Create</button>
      <button id="nc-create-run" class="ok">Create &amp; Run</button>
      <button id="nc-cancel">Cancel</button>
    </div>
  </dialog>

  <dialog id="diff-dialog">
    <h3 id="diff-title">Inspect Diff &amp; Conflicts</h3>
    <div id="diff-conflicts" class="badge-row"></div>
    <pre id="diff-body" class="diff-pre"></pre>
    <div class="card-actions">
      <button id="diff-close">Close</button>
    </div>
  </dialog>

  <dialog id="edit-dialog">
    <h3>Edit File &amp; Auto-Rebase Stack (<span id="edit-task-id"></span>)</h3>
    <div class="form-row">
      <label>Relative Path</label>
      <input id="edit-path" type="text" placeholder="lib/foo.dart" />
    </div>
    <div class="form-row">
      <label>New Content</label>
      <textarea id="edit-content" rows="8"></textarea>
    </div>
    <div class="card-actions">
      <button id="edit-save" class="primary">Save &amp; Cascade Rebase</button>
      <button id="edit-cancel">Cancel</button>
    </div>
  </dialog>

  <script>
    (() => {
      const meta = document.querySelector('meta[name="csrf-token"]');
      const csrfToken = meta ? meta.getAttribute('content') : '';
      let state = { session: {}, cards: [], processes: [], pendingPermissions: [], queuedRuns: [] };
      let editingTaskId = '';

      async function api(path, method = 'GET', body = null) {
        const opts = {
          method,
          headers: { 'X-CSRF-Token': csrfToken }
        };
        if (body !== null) {
          opts.headers['Content-Type'] = 'application/json';
          opts.body = JSON.stringify(body);
        }
        const res = await fetch(path, opts);
        if (!res.ok) {
          const text = await res.text();
          throw new Error(text || ('HTTP ' + res.status));
        }
        return res.json();
      }

      function laneForCard(card, pendingPerms) {
        const hasPerm = pendingPerms.some(p => p.taskId === card.taskId);
        if (hasPerm || card.state === 'conflict' || card.state === 'review' || card.hasConflicts) {
          return 'review';
        }
        if (card.state === 'paused' || card.state === 'stopped') {
          return 'paused';
        }
        if (card.state === 'running' || card.queued) {
          return 'running';
        }
        if (card.state === 'done') {
          return 'done';
        }
        return 'todo';
      }

      function render() {
        const s = state.session || {};
        document.getElementById('repo-pill').textContent = 'cwd: ' + (s.cwd || '-');
        document.getElementById('change-pill').textContent = 'change: ' + (s.jjChangeId || '-');
        document.getElementById('ctx-pill').textContent = 'swap: ' + (s.swappedDirtyPagesTotal || 0);

        const models = s.availableModels || [];
        const modelSel = document.getElementById('session-model');
        const ncModelSel = document.getElementById('nc-model');
        if (modelSel.options.length === 0 && models.length > 0) {
          for (const m of models) {
            const opt1 = document.createElement('option');
            opt1.value = m.value;
            opt1.textContent = m.name || m.value;
            modelSel.appendChild(opt1);
            const opt2 = document.createElement('option');
            opt2.value = m.value;
            opt2.textContent = m.name || m.value;
            ncModelSel.appendChild(opt2);
          }
        }
        if (s.currentModel) {
          modelSel.value = s.currentModel;
        }

        const cardIds = new Set((state.cards || []).map(c => c.taskId));
        const globalPermsEl = document.getElementById('global-permissions');
        globalPermsEl.textContent = '';
        const globalPerms = (state.pendingPermissions || []).filter(
          p => !p.taskId || !cardIds.has(p.taskId)
        );
        if (globalPerms.length > 0) {
          globalPermsEl.classList.add('visible');
          for (const perm of globalPerms) {
            globalPermsEl.appendChild(buildPermissionBox(perm));
          }
        } else {
          globalPermsEl.classList.remove('visible');
        }

        const lanes = { todo: [], running: [], paused: [], review: [], done: [] };
        for (const card of (state.cards || [])) {
          lanes[laneForCard(card, state.pendingPermissions || [])].push(card);
        }

        for (const key of Object.keys(lanes)) {
          const el = document.getElementById('lane-' + key);
          document.getElementById('count-' + key).textContent = String(lanes[key].length);
          el.innerHTML = '';
          for (const card of lanes[key]) {
            el.appendChild(buildCardElement(card));
          }
        }

        const parentSel = document.getElementById('nc-parent');
        const prev = parentSel.value;
        parentSel.innerHTML = '<option value="">(None — Root Task)</option>';
        for (const c of (state.cards || [])) {
          const opt = document.createElement('option');
          opt.value = c.taskId;
          opt.textContent = c.taskId + ': ' + (c.title || '');
          parentSel.appendChild(opt);
        }
        parentSel.value = prev;
      }

      function buildCardElement(card) {
        const div = document.createElement('div');
        div.className = 'card';
        div.dataset.taskId = card.taskId;

        const title = document.createElement('div');
        title.className = 'card-title';
        title.textContent = card.title || card.taskId;
        div.appendChild(title);

        const sub = document.createElement('div');
        sub.className = 'card-sub';
        sub.textContent = 'id: ' + card.taskId + (card.workingChangeId ? ' | chg: ' + card.workingChangeId : '');
        div.appendChild(sub);

        const badges = document.createElement('div');
        badges.className = 'badge-row';
        if (card.parentTaskId) {
          const b = document.createElement('span');
          b.className = 'badge';
          b.textContent = 'Stacked on: ' + card.parentTaskId;
          badges.appendChild(b);
        }
        if (card.queued) {
          const b = document.createElement('span');
          b.className = 'badge queued';
          b.textContent = 'Queued #' + card.queuePosition;
          badges.appendChild(b);
        }
        if (card.hasConflicts) {
          const b = document.createElement('span');
          b.className = 'badge conflict';
          b.textContent = 'Conflicts: ' + ((card.conflictedFiles || []).length);
          badges.appendChild(b);
        }
        div.appendChild(badges);

        if (card.streamText) {
          const pre = document.createElement('div');
          pre.className = 'stream-box';
          pre.textContent = card.streamText;
          div.appendChild(pre);
        }

        const actions = document.createElement('div');
        actions.className = 'card-actions';

        if (card.state === 'todo' && !card.queued) {
          const runBtn = document.createElement('button');
          runBtn.className = 'primary';
          runBtn.textContent = 'Run';
          runBtn.onclick = () => api('/api/cards/run', 'POST', {
            taskId: card.taskId,
            prompt: card.description || card.title,
            executionMode: card.executionMode || 'single',
            model: card.assignedModel || undefined
          }).then(refresh);
          actions.appendChild(runBtn);
        }

        if (card.state === 'running' || card.queued) {
          if (!card.queued) {
            const pauseBtn = document.createElement('button');
            pauseBtn.className = 'warn';
            pauseBtn.textContent = 'Pause (SIGSTOP)';
            pauseBtn.onclick = () => api('/api/signal', 'POST', {
              signal: 'SIGSTOP',
              taskId: card.taskId
            }).then(refresh);
            actions.appendChild(pauseBtn);
          }
          const killBtn = document.createElement('button');
          killBtn.className = 'danger';
          killBtn.textContent = 'Kill (SIGKILL)';
          killBtn.onclick = () => api('/api/signal', 'POST', {
            signal: 'SIGKILL',
            taskId: card.taskId
          }).then(refresh);
          actions.appendChild(killBtn);
        }

        if (card.state === 'paused' || card.state === 'stopped') {
          const inp = document.createElement('input');
          inp.type = 'text';
          inp.placeholder = 'Constraint for SIGCONT...';
          actions.appendChild(inp);
          const contBtn = document.createElement('button');
          contBtn.className = 'ok';
          contBtn.textContent = 'Inject & Resume (SIGCONT)';
          contBtn.onclick = () => api('/api/signal', 'POST', {
            signal: 'SIGCONT',
            taskId: card.taskId,
            constraintMessage: inp.value
          }).then(refresh);
          actions.appendChild(contBtn);
        }

        const diffBtn = document.createElement('button');
        diffBtn.textContent = 'Inspect Diff / Conflicts';
        diffBtn.onclick = () => openDiff(card.taskId);
        actions.appendChild(diffBtn);

        const editBtn = document.createElement('button');
        editBtn.textContent = 'Edit File & Auto-Rebase';
        editBtn.onclick = () => {
          editingTaskId = card.taskId;
          document.getElementById('edit-task-id').textContent = card.taskId;
          document.getElementById('edit-dialog').showModal();
        };
        actions.appendChild(editBtn);

        if (card.state === 'review') {
          const sqBtn = document.createElement('button');
          sqBtn.className = 'ok';
          sqBtn.textContent = 'Squash / Done';
          sqBtn.onclick = () => api('/api/squash', 'POST', { taskId: card.taskId }).then(refresh);
          actions.appendChild(sqBtn);
        }

        div.appendChild(actions);

        for (const perm of (state.pendingPermissions || [])) {
          if (perm.taskId === card.taskId || !perm.taskId) {
            div.appendChild(buildPermissionBox(perm));
          }
        }

        return div;
      }

      function buildPermissionBox(perm) {
        const box = document.createElement('div');
        box.className = 'perm-box';
        box.dataset.requestId = perm.requestId || '';

        const titleEl = document.createElement('div');
        titleEl.className = 'perm-title';
        titleEl.textContent = (perm.toolCall && perm.toolCall.title) || 'Approval Required';
        box.appendChild(titleEl);

        const meta = perm.approvalMeta || {};
        if (meta.pid !== undefined && meta.pid !== null && meta.pid !== 1) {
          const badgeRow = document.createElement('div');
          badgeRow.className = 'badge-row';
          const b = document.createElement('span');
          b.className = 'badge subprocess';
          b.textContent = 'Subprocess PID ' + meta.pid + (meta.profile ? ' (' + meta.profile + ')' : '');
          badgeRow.appendChild(b);
          box.appendChild(badgeRow);
        }

        if (meta.reason) {
          const reasonEl = document.createElement('div');
          reasonEl.className = 'perm-reason';
          reasonEl.textContent = 'Reason: ' + meta.reason;
          box.appendChild(reasonEl);
        }

        const previewParts = [];
        const rawContent = perm.toolCall && Array.isArray(perm.toolCall.content)
          ? perm.toolCall.content
          : [];
        for (const item of rawContent) {
          if (!item || typeof item !== 'object') continue;
          if (item.type === 'content' && item.content && typeof item.content.text === 'string' && item.content.text.trim()) {
            previewParts.push(item.content.text.trim());
          } else if (item.type === 'diff') {
            previewParts.push('diff: ' + (item.path || '(file)'));
          }
        }
        if (previewParts.length > 0) {
          const previewBox = document.createElement('div');
          previewBox.className = 'stream-box';
          previewBox.textContent = previewParts.join('\n');
          box.appendChild(previewBox);
        }

        const btnRow = document.createElement('div');
        btnRow.className = 'card-actions';
        const opts = (Array.isArray(perm.options) && perm.options.length > 0)
          ? perm.options
          : [
              { optionId: 'allow_once', name: 'Allow once' },
              { optionId: 'allow_always', name: 'Allow always' },
              { optionId: 'reject_once', name: 'Deny' }
            ];
        for (const opt of opts) {
          const btn = document.createElement('button');
          if (opt.optionId === 'reject_once') {
            btn.className = 'danger';
          } else if (opt.optionId === 'allow_always') {
            btn.className = 'primary';
          } else {
            btn.className = 'ok';
          }
          btn.textContent = opt.name || opt.optionId;
          btn.onclick = () => api('/api/permissions/respond', 'POST', {
            requestId: perm.requestId,
            optionId: opt.optionId
          }).then(refresh);
          btnRow.appendChild(btn);
        }
        box.appendChild(btnRow);
        return box;
      }

      async function openDiff(taskId) {
        const res = await api('/api/diff', 'POST', { taskId });
        document.getElementById('diff-title').textContent = 'Diff & Conflicts: ' + taskId;
        const cEl = document.getElementById('diff-conflicts');
        cEl.innerHTML = '';
        for (const f of (res.conflictedFiles || [])) {
          const b = document.createElement('span');
          b.className = 'badge conflict';
          b.textContent = f;
          cEl.appendChild(b);
        }
        document.getElementById('diff-body').textContent = res.diff || '(no diff)';
        document.getElementById('diff-dialog').showModal();
      }

      async function refresh() {
        try {
          state = await api('/api/state', 'GET');
          render();
        } catch (err) {
          console.error(err);
        }
      }

      function connectWs() {
        const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
        const ws = new WebSocket(proto + '//' + location.host + '/ws?token=' + encodeURIComponent(csrfToken));
        ws.onmessage = (ev) => {
          try {
            const msg = JSON.parse(ev.data);
            if (msg.type === 'snapshot') {
              state = msg;
              render();
            } else {
              refresh();
            }
          } catch (_) {}
        };
        ws.onclose = () => setTimeout(connectWs, 1500);
      }

      document.getElementById('session-model').onchange = (e) => {
        api('/api/model', 'POST', { model: e.target.value }).then(refresh);
      };
      document.getElementById('btn-new-card').onclick = () => {
        document.getElementById('new-card-dialog').showModal();
      };
      document.getElementById('nc-cancel').onclick = () => {
        document.getElementById('new-card-dialog').close();
      };
      document.getElementById('nc-create').onclick = () => submitNewCard(false);
      document.getElementById('nc-create-run').onclick = () => submitNewCard(true);

      async function submitNewCard(autoStart) {
        const title = document.getElementById('nc-title').value.trim();
        const prompt = document.getElementById('nc-prompt').value.trim();
        const executionMode = document.getElementById('nc-mode').value;
        const parentTaskId = document.getElementById('nc-parent').value || null;
        const model = document.getElementById('nc-model').value || null;
        if (!title) return;
        await api('/api/cards', 'POST', {
          title,
          description: prompt || title,
          prompt: prompt || title,
          executionMode,
          parentTaskId,
          model,
          autoStart
        });
        document.getElementById('new-card-dialog').close();
        await refresh();
      }

      document.getElementById('diff-close').onclick = () => {
        document.getElementById('diff-dialog').close();
      };
      document.getElementById('edit-cancel').onclick = () => {
        document.getElementById('edit-dialog').close();
      };
      document.getElementById('edit-save').onclick = async () => {
        const relativePath = document.getElementById('edit-path').value.trim();
        const content = document.getElementById('edit-content').value;
        if (!editingTaskId || !relativePath) return;
        await api('/api/cards/edit', 'POST', { taskId: editingTaskId, relativePath, content });
        document.getElementById('edit-dialog').close();
        await refresh();
      };

      document.getElementById('btn-global-stop').onclick = () => {
        api('/api/signal', 'POST', { signal: 'SIGSTOP', pid: 1 }).then(refresh);
      };
      document.getElementById('btn-global-cont').onclick = () => {
        api('/api/signal', 'POST', { signal: 'SIGCONT', pid: 1 }).then(refresh);
      };
      document.getElementById('btn-shutdown').onclick = () => {
        api('/api/shutdown', 'POST', {});
      };

      refresh();
      connectWs();
    })();
  </script>
</body>
</html>
''';

import {Socket} from 'phoenix';
import {LiveSocket} from 'phoenix_live_view';
import {Terminal} from '@xterm/xterm';
import {FitAddon} from '@xterm/addon-fit';
import '@fontsource-variable/dm-sans';
import '@fontsource-variable/jetbrains-mono';
import '@xterm/xterm/css/xterm.css';
import '../css/app.css';

const Hooks = {
  Intent: {
    mounted() {
      this.key = `smolbox-intent:${this.el.id}`;
      this.token = sessionStorage.getItem(this.key) || crypto.randomUUID();
      this.save = () => {
        sessionStorage.setItem(this.key, this.token);
        this.el.querySelector('[name="token"]').value = this.token;
      };
      this.newIntent = () => { this.token = crypto.randomUUID(); this.save(); };
      this.signature = () => JSON.stringify([...this.el.querySelectorAll('input,select,textarea')].filter(el => el.name && el.name !== 'token').map(el => [el.name, el.type === 'file' ? [...el.files].map(f => [f.name,f.size,f.lastModified]) : el.value]));
      this.lastSignature = this.signature();
      this.onInput = event => {
        const signature = this.signature();
        if (event.target.name !== 'token' && signature !== this.lastSignature) { this.lastSignature = signature; this.newIntent(); }
      };
      this.el.addEventListener('input', this.onInput, true);
      this.el.addEventListener('change', this.onInput, true);
      this.handleEvent('new-intent', ({form}) => { if (form === this.el.id) this.newIntent(); });
      this.save();
    },
    updated() { this.save(); },
    destroyed() { this.el.removeEventListener('input', this.onInput, true); this.el.removeEventListener('change', this.onInput, true); }
  },
  Terminal: {
    mounted() {
      this.active = false;
      this.warnBeforeLeaving = event => {
        if (!this.active) return;
        event.preventDefault();
        event.returnValue = '';
      };
      window.addEventListener('beforeunload', this.warnBeforeLeaving);
      this.pendingInput = false;
      this.inputQueue = '';
      this.fit = new FitAddon();
      this.term = new Terminal({fontFamily:'"JetBrains Mono Variable", monospace', fontSize:13, lineHeight:1.5, cursorBlink:true, scrollback:1500, screenReaderMode:true, theme:{background:'#22261f',foreground:'#eff1e6',cursor:'#d2e789',brightBlack:'#bfc7af',selectionBackground:'#596449'}});
      this.term.loadAddon(this.fit);
      this.el.replaceChildren();
      this.term.open(this.el);
      this.fit.fit();
      this.term.writeln('\x1b[90mOpen a terminal to connect to your guest shell.\x1b[0m');
      this.resize = new ResizeObserver(() => {
        this.fit.fit();
        if (this.active) this.pushEvent('terminal-resize', {cols:this.term.cols,rows:this.term.rows});
      });
      this.resize.observe(this.el);
      this.term.attachCustomKeyEventHandler(event => {
        if (event.type === 'keydown' && event.key === 'Escape') {
          this.el.closest('section').querySelector('button')?.focus();
          return false;
        }
        return true;
      });
      this.flushInput = () => {
        if (!this.active || this.pendingInput || !this.inputQueue) return;
        const bytes = new TextEncoder().encode(this.inputQueue);
        this.inputQueue = '';
        if (bytes.length > 16384) { this.term.writeln('\r\nInput exceeds 16 KiB. Paste a smaller chunk.'); return; }
        this.pendingInput = true;
        const encoded = btoa(String.fromCharCode(...bytes));
        this.pushEvent('terminal-input', {bytes:encoded}, reply => {
          this.pendingInput = false;
          if (!reply.ok) { this.active=false; this.term.writeln('\r\nInput was not accepted. Check the recorded terminal state.'); }
          else this.flushInput();
        });
      };
      this.input = this.term.onData(data => {
        if (!this.active) return;
        if (this.inputQueue.length + data.length > 16384) { this.term.writeln('\r\nInput queue is full. Paste a smaller chunk.'); return; }
        this.inputQueue += data;
        this.flushInput();
      });
      this.handleEvent('terminal-ready', ({resumed}) => {
        this.active=true; this.pendingInput=false; this.inputQueue=''; this.term.clear(); this.fit.fit();
        if (resumed) this.term.writeln('\r\nReconnected to the same shell. Previous output is not saved; press Enter for its prompt.');
        else this.term.focus();
        this.pushEvent('terminal-resize',{cols:this.term.cols,rows:this.term.rows});
      });
      this.handleEvent('terminal-output', ({seq,bytes}) => {
        const decoded=Uint8Array.from(atob(bytes), c=>c.charCodeAt(0));
        this.term.write(decoded, () => this.pushEvent('terminal-ack',{seq}));
      });
      this.handleEvent('terminal-closed', ({message}) => {
        this.active=false; this.term.writeln(`\r\n\x1b[90m${message}\x1b[0m`);
      });
      this.handleEvent('terminal-recovered', () => {
        if (!this.active) { this.term.clear(); this.term.writeln('\r\nWorkspace available. Open a terminal to start a new shell.'); }
      });
    },
    disconnected() { this.active=false; this.inputQueue=''; },
    reconnected() { this.pushEvent('resume-terminal',{}); },
    destroyed() { window.removeEventListener('beforeunload', this.warnBeforeLeaving); this.resize.disconnect(); this.input.dispose(); this.term.dispose(); }
  }
};
const csrfToken=document.querySelector('meta[name="csrf-token"]').getAttribute('content');
const liveSocket=new LiveSocket('/live',Socket,{
  params:{_csrf_token:csrfToken},
  hooks:Hooks,
  dom:{
    onBeforeElUpdated(fromEl,toEl) {
      // Disclosure state belongs to the browser; keep live content updating inside it.
      if (fromEl.tagName === 'DETAILS' && toEl.tagName === 'DETAILS') {
        toEl.open = fromEl.open;
      }
    }
  }
});
liveSocket.connect();

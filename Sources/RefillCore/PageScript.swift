/// Wi-Fi Refill's script for a login page's web view. It runs in a content world of its own in every frame: the page
/// shares the DOM with it, never its variables. While teaching it reports each press the person makes, and just before
/// it what they typed into the page's fields; during a replay it reports what can be pressed and filled, and presses
/// and fills what it is told.
public enum PageScript {
    public static func source(teaching: Bool) -> String {
        #"""
        (() => {
          const teaching = \#(teaching);
          // Not crypto.randomUUID: login pages are often plain HTTP, where it does not exist.
          const documentID = Math.random().toString(36).slice(2) + Date.now().toString(36);
          const post = (message) => window.webkit.messageHandlers.refill.postMessage(message);
          const clean = (text) => (text || '').replace(/\s+/g, ' ').trim().slice(0, 120) || null;
          const pressable = 'button, a[href], input[type=button], input[type=submit], input[type=image], input[type=checkbox], input[type=radio], [role=button], [onclick]';
          const buttonTypes = ['button', 'submit', 'image', 'reset'];
          const choiceTypes = ['checkbox', 'radio'];
          const typeOf = (element) => (element.getAttribute('type') || '').toLowerCase();
          // Anything a person can put data into.
          const editable = (node) => node instanceof Element && (node.isContentEditable || ['TEXTAREA', 'SELECT'].includes(node.tagName)
            || (node.tagName === 'INPUT' && ![...buttonTypes, ...choiceTypes, 'hidden'].includes(typeOf(node) || 'text')));
          const fields = 'textarea, select, [contenteditable]:not([contenteditable=false]), input:not([type=button]):not([type=submit]):not([type=image]):not([type=reset]):not([type=checkbox]):not([type=radio]):not([type=hidden])';
          // A button that is, or wraps, somewhere to type: its text could be what the person typed.
          const holdsData = (element) => editable(element) || element.querySelector(fields) !== null;
          const describe = (element) => {
            const input = element.tagName === 'INPUT', type = typeOf(element);
            // An input's value only when it is a button's caption: never anything typed.
            const caption = input ? (buttonTypes.includes(type) ? element.value : null) : element.innerText;
            return {
              origin: location.origin, path: location.pathname, tag: element.tagName.toLowerCase(),
              id: element.id || null, name: element.getAttribute('name'), type: type || null, role: element.getAttribute('role'),
              label: clean(element.getAttribute('aria-label')),
              text: clean(caption) || clean(element.getAttribute('title') || element.getAttribute('alt') || element.getAttribute('placeholder')),
              checked: input && choiceTypes.includes(type) ? element.checked : null,
            };
          };
          const visible = (element) => {
            const box = element.getBoundingClientRect();
            return box.width > 0 && box.height > 0 && getComputedStyle(element).visibility !== 'hidden';
          };
          const usable = (element) => visible(element) && !element.disabled && element.getAttribute('aria-disabled') !== 'true' && !holdsData(element);
          // A field Wi-Fi Refill can fill in again: an input, text area or menu in the document itself.
          const fillable = (node) => node instanceof Element && editable(node) && !node.isContentEditable && node.getRootNode() === document;
          if (teaching) {
            // Fields the person typed into since their last press, in the order they first did.
            const typed = new Set();
            let lastPress = null, lastPressAt = 0;
            // What they typed goes with the press that sends it, so a field corrected before pressing is taught as left.
            const flush = () => {
              for (const field of typed) {
                if (field.isConnected) post({ kind: 'fill', element: { ...describe(field), fill: true }, value: field.value });
              }
              typed.clear();
            };
            const press = (element) => {
              // A replay looks for buttons in the document, not inside components' shadow trees.
              if (element.getRootNode() !== document) return post({ kind: 'unlearnable' });
              flush();
              lastPress = element;
              lastPressAt = performance.now();
              post({ kind: 'press', element: describe(element) });
            };
            // Described at once, before the page's own handlers can change the element. A label passes its click on to
            // its control, which reports it; the label itself is not a step.
            document.addEventListener('click', (event) => {
              if (!event.isTrusted) return;
              const path = event.composedPath();
              // A click into a field is not a press.
              if (path.some(editable)) return;
              const element = path.find((node) => node instanceof Element && node.matches(pressable));
              if (!element || holdsData(element)) return;
              press(element);
            }, true);
            // Return in a field sends its form without a click: that is a press of the form's button.
            document.addEventListener('submit', (event) => {
              if (!event.isTrusted) return;
              const form = event.target;
              const button = event.submitter || form.querySelector('button:not([type=button]):not([type=reset]), input[type=submit], input[type=image]');
              if (button && button === lastPress && performance.now() - lastPressAt < 1000) return;
              if (!button) return post({ kind: 'unlearnable' });
              press(button);
            }, true);
            // Typing is noted where it happens, shadow trees included; only ticking a box is a press of its own.
            for (const type of ['beforeinput', 'input', 'paste', 'compositionstart', 'change']) {
              document.addEventListener(type, (event) => {
                if (!event.isTrusted) return;
                const target = event.composedPath()[0];
                if (target instanceof Element && target.tagName === 'INPUT' && choiceTypes.includes(typeOf(target))) return;
                if (fillable(target)) typed.add(target); else post({ kind: 'typing' });
              }, true);
            }
          } else {
            const tokens = new WeakMap(), byToken = new Map();
            let next = 1;
            const tokenOf = (element) => {
              if (!tokens.has(element)) { tokens.set(element, next); byToken.set(next, new WeakRef(element)); next += 1; }
              return tokens.get(element);
            };
            window.__refill = {
              // Presses exactly the element that was matched, in the document that reported it, if it is still usable.
              press: (document, token) => {
                if (document !== documentID) return false;
                const element = byToken.get(token)?.deref();
                if (!element || !element.isConnected || !usable(element)) return false;
                element.scrollIntoView({ block: 'center' });
                element.click();
                return true;
              },
              // Types what the person taught into exactly the field that was matched, as typing would: through the
              // field's own setter, so pages built with frameworks notice, then the events typing sends.
              fill: (document, token, value) => {
                if (document !== documentID) return false;
                const field = byToken.get(token)?.deref();
                if (!field || !field.isConnected || !visible(field) || field.disabled || field.readOnly) return false;
                field.scrollIntoView({ block: 'center' });
                field.focus();
                const prototype = field.tagName === 'SELECT' ? HTMLSelectElement.prototype : field.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                Object.getOwnPropertyDescriptor(prototype, 'value').set.call(field, value);
                field.dispatchEvent(new Event('input', { bubbles: true }));
                field.dispatchEvent(new Event('change', { bubbles: true }));
                return field.value === value;
              },
            };
            setInterval(() => {
              const found = [...document.querySelectorAll(pressable)].filter(usable).slice(0, 200);
              const boxes = [...document.querySelectorAll(fields)].filter((field) => fillable(field) && visible(field) && !field.disabled).slice(0, 50);
              post({ kind: 'page', document: documentID, elements: [
                ...found.map((element) => ({ ...describe(element), token: tokenOf(element) })),
                ...boxes.map((field) => ({ ...describe(field), fill: true, token: tokenOf(field) })),
              ] });
            }, 500);
          }
        })();
        """#
    }
}

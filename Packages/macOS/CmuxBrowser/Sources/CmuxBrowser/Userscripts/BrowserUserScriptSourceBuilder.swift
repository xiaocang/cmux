import Foundation

/// Builds guarded JavaScript wrappers for installed userscripts.
public struct BrowserUserScriptSourceBuilder: Sendable {
    /// Creates a source builder.
    public init() {}

    /// Builds a guarded script for WebKit injection.
    /// - Parameters:
    ///   - script: The userscript to wrap.
    ///   - nativeBridgeMessageHandlerName: Optional WebKit message handler used
    ///     for privileged GM APIs.
    ///   - nativeBridgeToken: Per-script token accepted by the native bridge.
    /// - Returns: JavaScript that checks the current URL, installs the cmux
    ///   userscript compatibility runtime, and evaluates the userscript.
    public func wrappedSource(
        for script: BrowserUserScript,
        nativeBridgeMessageHandlerName: String? = nil,
        nativeBridgeToken: String? = nil
    ) -> String {
        let metadata = script.metadata
        let payload: [String: Any] = [
            "id": script.id,
            "name": metadata.name,
            "namespace": metadata.namespace ?? "",
            "version": metadata.version ?? "",
            "description": metadata.description ?? "",
            "author": metadata.author ?? "",
            "copyright": metadata.copyright ?? "",
            "icon": metadata.icon ?? "",
            "icon64": metadata.icon64 ?? "",
            "homepage": metadata.homepage ?? "",
            "updateURL": metadata.updateURL ?? "",
            "downloadURL": metadata.downloadURL ?? "",
            "supportURL": metadata.supportURL ?? "",
            "antifeatures": metadata.antifeatures,
            "tags": metadata.tags,
            "matches": metadata.matches,
            "includes": metadata.includes,
            "excludeMatches": metadata.excludeMatches,
            "excludes": metadata.excludes,
            "runAt": metadata.runAt.rawValue,
            "grants": metadata.grants,
            "requires": metadata.requires,
            "resources": metadata.resources,
            "connects": metadata.connects,
            "noframes": metadata.noframes,
            "runIn": metadata.runIn,
            "sandbox": metadata.sandbox ?? "",
            "webRequests": metadata.webRequests,
            "unwrap": metadata.unwrap
        ]
        let payloadLiteral = jsonLiteral(payload)
        let bridgeNameLiteral = nativeBridgeMessageHandlerName.map(jsonLiteral) ?? "null"
        let bridgeTokenLiteral = nativeBridgeToken.map(jsonLiteral) ?? "null"
        let sourceURL = "cmux-userscript-\(script.id).user.js"
        let userSource = script.source
        let userSourceLiteral = jsonLiteral(userSource)
        let invoke = """
            const __cmuxInvokeUserscript = () => {
              const __cmuxGrantValues = Array.isArray(__cmuxUserscript.grants)
                ? __cmuxUserscript.grants.map((grant) => String(grant || '').trim()).filter(Boolean)
                : [];
              const __cmuxGrantNameSet = new Set(__cmuxGrantValues.map((grant) => grant.toLowerCase()));
              const __cmuxGrantNone = __cmuxGrantNameSet.has('none');
              const __cmuxHasAnyGrant = (names) => {
                if (__cmuxGrantNone) return false;
                return names.some((name) => __cmuxGrantNameSet.has(String(name || '').toLowerCase()));
              };
              const __cmuxExpose = (value, names) => __cmuxHasAnyGrant(names) ? value : undefined;
              const __cmuxSandboxMode = (() => {
                if (__cmuxGrantNone) return 'raw';
                const value = String(__cmuxUserscript.sandbox || '').trim().toLowerCase();
                if (value === 'raw') return 'raw';
                if (value === 'dom') return 'dom';
                if (value === 'javascript' || value === 'js') return 'js';
                return 'js';
              })();
              const __cmuxInfoResources = () => Object.entries(__cmuxUserscript.resources || {}).map(([name, url]) => ({
                name: String(name),
                url: String(url || '')
              }));
              const __cmuxInfoWebRequests = () => {
                const rules = typeof __cmuxHeaderWebRequestRules === 'function' ? __cmuxHeaderWebRequestRules() : [];
                return rules.length ? rules : null;
              };
              const __cmuxInfoScript = () => ({
                antifeatures: __cmuxUserscript.antifeatures || [],
                author: __cmuxUserscript.author || null,
                blockers: [],
                connects: __cmuxUserscript.connects || [],
                copyright: __cmuxUserscript.copyright || null,
                description_i18n: null,
                description: __cmuxUserscript.description || '',
                downloadURL: __cmuxUserscript.downloadURL || null,
                excludes: __cmuxUserscript.excludes || [],
                fileURL: null,
                grant: __cmuxGrantValues.slice(),
                header: null,
                homepage: __cmuxUserscript.homepage || null,
                icon: __cmuxUserscript.icon || null,
                icon64: __cmuxUserscript.icon64 || null,
                includes: __cmuxUserscript.includes || [],
                lastModified: 0,
                matches: __cmuxUserscript.matches || [],
                name_i18n: null,
                name: __cmuxUserscript.name || '',
                namespace: __cmuxUserscript.namespace || null,
                position: 0,
                resources: __cmuxInfoResources(),
                supportURL: __cmuxUserscript.supportURL || null,
                'run-at': __cmuxUserscript.runAt || null,
                'run-in': (__cmuxUserscript.runIn || []).length ? __cmuxUserscript.runIn : null,
                unwrap: !!__cmuxUserscript.unwrap,
                updateURL: __cmuxUserscript.updateURL || null,
                version: __cmuxUserscript.version || '',
                webRequest: __cmuxInfoWebRequests(),
                options: {
                  check_for_updates: !!__cmuxUserscript.updateURL,
                  comment: null,
                  compatopts_for_requires: true,
                  compat_wrappedjsobject: false,
                  compat_metadata: true,
                  compat_foreach: false,
                  compat_powerful_this: null,
                  sandbox: __cmuxUserscript.sandbox || null,
                  noframes: !!__cmuxUserscript.noframes,
                  unwrap: !!__cmuxUserscript.unwrap,
                  run_at: __cmuxUserscript.runAt || null,
                  run_in: (__cmuxUserscript.runIn || []).length ? __cmuxUserscript.runIn.join(',') : null,
                  override: {
                    use_includes: __cmuxUserscript.includes || [],
                    orig_includes: __cmuxUserscript.includes || [],
                    merge_includes: true,
                    use_matches: __cmuxUserscript.matches || [],
                    orig_matches: __cmuxUserscript.matches || [],
                    merge_matches: true,
                    use_excludes: __cmuxUserscript.excludes || [],
                    orig_excludes: __cmuxUserscript.excludes || [],
                    merge_excludes: true,
                    use_connects: __cmuxUserscript.connects || [],
                    orig_connects: __cmuxUserscript.connects || [],
                    merge_connects: true,
                    use_blockers: [],
                    orig_run_at: __cmuxUserscript.runAt || null,
                    orig_run_in: (__cmuxUserscript.runIn || []).length ? __cmuxUserscript.runIn : null,
                    orig_noframes: !!__cmuxUserscript.noframes
                  }
                }
              });
              const GM_info = {
                downloadMode: 'browser',
                isIncognito: false,
                sandboxMode: __cmuxSandboxMode,
                scriptHandler: 'cmux',
                scriptMetaStr: null,
                scriptUpdateURL: __cmuxUserscript.updateURL || null,
                scriptWillUpdate: !!__cmuxUserscript.updateURL,
                userAgentData: {
                  platform: navigator.platform || 'macOS',
                  mobile: false
                },
                version: '1',
                script: __cmuxInfoScript()
              };
              const __cmuxUnsafeWindow = window;
              const unsafeWindow = __cmuxExpose(__cmuxUnsafeWindow, ['unsafeWindow']);
              const __cmuxNativeBridgeName = \(bridgeNameLiteral);
              const __cmuxNativeBridgeToken = \(bridgeTokenLiteral);
              const __cmuxNativePost = (payload) => {
                if (!__cmuxNativeBridgeName || !__cmuxNativeBridgeToken) return null;
                const handlers = window.webkit && window.webkit.messageHandlers;
                const handler = handlers && handlers[__cmuxNativeBridgeName];
                if (!handler || typeof handler.postMessage !== 'function') return null;
                const message = Object.assign({
                  scriptId: __cmuxUserscript.id,
                  token: __cmuxNativeBridgeToken
                }, payload || {});
                try {
                  const reply = handler.postMessage(message);
                  return reply && typeof reply.then === 'function' ? reply : null;
                } catch (_) {
                  return null;
                }
              };
              const __cmuxResolveURL = (rawURL) => new URL(String(rawURL || ''), String(location.href || 'about:blank')).href;
              const __cmuxDefaultPort = (scheme) => scheme === 'http:' || scheme === 'http' ? '80' : (scheme === 'https:' || scheme === 'https' ? '443' : '');
              const __cmuxHostMatches = (pattern, host) => {
                pattern = String(pattern || '').toLowerCase();
                host = String(host || '').toLowerCase();
                if (pattern === '*') return true;
                if (pattern.startsWith('*.')) {
                  const suffix = pattern.slice(2);
                  return host === suffix || host.endsWith('.' + suffix);
                }
                if (pattern.includes('*')) return __cmuxGlobMatches(pattern, host);
                return host === pattern || host.endsWith('.' + pattern);
              };
              const __cmuxCanConnect = (rawURL) => {
                let target;
                try { target = new URL(__cmuxResolveURL(rawURL)); } catch (_) { return false; }
                if (target.protocol !== 'http:' && target.protocol !== 'https:') return false;
                const rules = Array.isArray(__cmuxUserscript.connects) ? __cmuxUserscript.connects.filter(Boolean) : [];
                if (rules.length === 0) return true;
                return rules.some((rule) => {
                  rule = String(rule || '').trim().toLowerCase();
                  if (!rule) return false;
                  if (rule === '*') return true;
                  if (rule === 'self') {
                    return target.protocol === location.protocol
                      && target.hostname.toLowerCase() === location.hostname.toLowerCase()
                      && (target.port || __cmuxDefaultPort(target.protocol)) === (location.port || __cmuxDefaultPort(location.protocol));
                  }
                  const schemeSplit = rule.split('://');
                  if (schemeSplit.length === 2) {
                    const schemeRule = schemeSplit[0];
                    if (schemeRule !== '*' && schemeRule + ':' !== target.protocol) return false;
                    const rest = schemeSplit[1];
                    const slash = rest.indexOf('/');
                    const hostRule = slash >= 0 ? rest.slice(0, slash) : rest;
                    const pathRule = slash >= 0 ? rest.slice(slash) : '*';
                    return __cmuxHostMatches(hostRule, target.hostname) && __cmuxGlobMatches(pathRule, target.pathname || '/');
                  }
                  return __cmuxHostMatches(rule, target.hostname);
                });
              };
              const __cmuxInstallURLChangeSupport = () => {
                if (window.__cmuxUserscriptURLChangeInstalled) return;
                try {
                  Object.defineProperty(window, '__cmuxUserscriptURLChangeInstalled', { value: true });
                } catch (_) {
                  window.__cmuxUserscriptURLChangeInstalled = true;
                }
                let onURLChangeHandler = typeof window.onurlchange === 'function' ? window.onurlchange : null;
                try {
                  Object.defineProperty(window, 'onurlchange', {
                    configurable: true,
                    enumerable: true,
                    get: () => onURLChangeHandler,
                    set: (handler) => { onURLChangeHandler = typeof handler === 'function' ? handler : null; }
                  });
                } catch (_) {
                  window.onurlchange = onURLChangeHandler;
                }
                let previousURL = String(location.href || '');
                const dispatchURLChange = () => {
                  const nextURL = String(location.href || '');
                  if (nextURL === previousURL) return;
                  const oldURL = previousURL;
                  previousURL = nextURL;
                  const event = new CustomEvent('urlchange', {
                    detail: { url: nextURL, oldURL }
                  });
                  try {
                    Object.defineProperty(event, 'url', { value: nextURL });
                    Object.defineProperty(event, 'oldURL', { value: oldURL });
                  } catch (_) {}
                  window.dispatchEvent(event);
                  if (typeof onURLChangeHandler === 'function') {
                    try { onURLChangeHandler.call(window, event); } catch (error) { setTimeout(() => { throw error; }, 0); }
                  }
                };
                for (const method of ['pushState', 'replaceState']) {
                  const original = history[method];
                  if (typeof original !== 'function') continue;
                  history[method] = function(...args) {
                    const result = original.apply(this, args);
                    setTimeout(dispatchURLChange, 0);
                    return result;
                  };
                }
                window.addEventListener('popstate', dispatchURLChange, true);
                window.addEventListener('hashchange', dispatchURLChange, true);
              };
              if (__cmuxHasAnyGrant(['window.onurlchange'])) {
                __cmuxInstallURLChangeSupport();
              }
              const __cmuxStoragePrefix = '__cmux_userscript:' + __cmuxUserscript.id + ':';
              const __cmuxStoredValues = Object.create(null);
              const __cmuxValueListeners = new Map();
              let __cmuxNextValueListenerID = 1;
              const __cmuxLoadFallbackValues = () => {
                for (let i = 0; i < localStorage.length; i++) {
                  const key = localStorage.key(i);
                  if (!key || !key.startsWith(__cmuxStoragePrefix)) continue;
                  const storeKey = key.slice(__cmuxStoragePrefix.length);
                  const raw = localStorage.getItem(key);
                  try { __cmuxStoredValues[storeKey] = JSON.parse(raw); } catch (_) { __cmuxStoredValues[storeKey] = raw; }
                }
              };
              const __cmuxHydrateValues = () => {
                const nativeReply = __cmuxNativePost({ type: 'value.getAll' });
                if (!nativeReply) {
                  __cmuxLoadFallbackValues();
                  return Promise.resolve();
                }
                return nativeReply.then((payload) => {
                  const values = payload && payload.values && typeof payload.values === 'object' ? payload.values : {};
                  for (const key of Object.keys(__cmuxStoredValues)) delete __cmuxStoredValues[key];
                  Object.assign(__cmuxStoredValues, values);
                }).catch(() => {
                  __cmuxLoadFallbackValues();
                });
              };
              const __cmuxPersistValueSet = (key, value) => {
                localStorage.setItem(__cmuxStoragePrefix + String(key), JSON.stringify(value));
                const nativeReply = __cmuxNativePost({ type: 'value.set', key: String(key), value });
                if (nativeReply) nativeReply.catch(() => {});
              };
              const __cmuxPersistValueDelete = (key) => {
                localStorage.removeItem(__cmuxStoragePrefix + String(key));
                const nativeReply = __cmuxNativePost({ type: 'value.delete', key: String(key) });
                if (nativeReply) nativeReply.catch(() => {});
              };
              const __cmuxPersistValueSetMany = (values) => {
                for (const [key, value] of Object.entries(values || {})) {
                  localStorage.setItem(__cmuxStoragePrefix + String(key), JSON.stringify(value));
                }
                const nativeReply = __cmuxNativePost({ type: 'value.setMany', values: values || {} });
                if (nativeReply) nativeReply.catch(() => {});
              };
              const __cmuxPersistValueDeleteMany = (keys) => {
                for (const key of keys) localStorage.removeItem(__cmuxStoragePrefix + String(key));
                const nativeReply = __cmuxNativePost({ type: 'value.deleteMany', keys });
                if (nativeReply) nativeReply.catch(() => {});
              };
              const GM_getValue = (key, defaultValue) => {
                const storeKey = String(key);
                return Object.prototype.hasOwnProperty.call(__cmuxStoredValues, storeKey)
                  ? __cmuxStoredValues[storeKey]
                  : defaultValue;
              };
              const __cmuxNotifyValueListeners = (key, oldValue, newValue) => {
                for (const listener of __cmuxValueListeners.values()) {
                  if (listener.key !== String(key)) continue;
                  setTimeout(() => listener.callback(String(key), oldValue, newValue, false), 0);
                }
              };
              const GM_setValue = (key, value) => {
                const oldValue = GM_getValue(key);
                __cmuxStoredValues[String(key)] = value;
                __cmuxPersistValueSet(key, value);
                __cmuxNotifyValueListeners(key, oldValue, value);
              };
              const GM_deleteValue = (key) => {
                const oldValue = GM_getValue(key);
                delete __cmuxStoredValues[String(key)];
                __cmuxPersistValueDelete(key);
                __cmuxNotifyValueListeners(key, oldValue, undefined);
              };
              const GM_listValues = () => {
                return Object.keys(__cmuxStoredValues);
              };
              const GM_setValues = (values) => {
                const entries = Object.entries(values || {});
                const oldValues = {};
                for (const [key, value] of entries) {
                  oldValues[key] = GM_getValue(key);
                  __cmuxStoredValues[String(key)] = value;
                }
                __cmuxPersistValueSetMany(values || {});
                for (const [key, value] of entries) __cmuxNotifyValueListeners(key, oldValues[key], value);
              };
              const GM_getValues = (keysOrDefaults) => {
                const values = {};
                if (Array.isArray(keysOrDefaults)) {
                  for (const key of keysOrDefaults) values[key] = GM_getValue(key);
                } else if (keysOrDefaults && typeof keysOrDefaults === 'object') {
                  for (const [key, defaultValue] of Object.entries(keysOrDefaults)) values[key] = GM_getValue(key, defaultValue);
                } else {
                  for (const key of GM_listValues()) values[key] = GM_getValue(key);
                }
                return values;
              };
              const GM_deleteValues = (keys) => {
                const actualKeys = Array.isArray(keys) ? keys.map(String) : Object.keys(keys || {});
                const oldValues = {};
                for (const key of actualKeys) {
                  oldValues[key] = GM_getValue(key);
                  delete __cmuxStoredValues[String(key)];
                }
                __cmuxPersistValueDeleteMany(actualKeys);
                for (const key of actualKeys) __cmuxNotifyValueListeners(key, oldValues[key], undefined);
              };
              const __cmuxPromiseReturn = (fn) => new Promise((resolve, reject) => {
                try { resolve(fn()); } catch (error) { reject(error); }
              });
              const GM_addValueChangeListener = (key, callback) => {
                const id = __cmuxNextValueListenerID++;
                __cmuxValueListeners.set(id, { key: String(key), callback: typeof callback === 'function' ? callback : () => {} });
                return id;
              };
              const GM_removeValueChangeListener = (id) => {
                __cmuxValueListeners.delete(id);
              };
              const GM_addStyle = (css) => {
                const el = document.createElement('style');
                el.textContent = String(css || '');
                (document.head || document.documentElement || document.body).appendChild(el);
                return el;
              };
              const GM_addElement = (...args) => {
                let parent = document.body || document.documentElement;
                let tagName = args[0];
                let attrs = args[1] || {};
                if (typeof args[0] !== 'string') {
                  parent = args[0] || parent;
                  tagName = args[1];
                  attrs = args[2] || {};
                }
                const el = document.createElement(String(tagName || 'div'));
                for (const [key, value] of Object.entries(attrs || {})) {
                  if (key === 'textContent') el.textContent = String(value);
                  else if (key === 'innerHTML') el.innerHTML = String(value);
                  else if (key in el) {
                    try { el[key] = value; } catch (_) { el.setAttribute(key, String(value)); }
                  } else {
                    el.setAttribute(key, String(value));
                  }
                }
                parent.appendChild(el);
                return el;
              };
              const __cmuxMenuCommands = new Map();
              let __cmuxNextMenuCommandID = 1;
              const GM_registerMenuCommand = (name, callback) => {
                const id = __cmuxNextMenuCommandID++;
                __cmuxMenuCommands.set(id, { name: String(name || ''), callback });
                return id;
              };
              const GM_unregisterMenuCommand = (id) => {
                __cmuxMenuCommands.delete(id);
              };
              const __cmuxApplyResponseType = (payload, request) => {
                const type = String((request || {}).responseType || '').toLowerCase();
                if (request && Object.prototype.hasOwnProperty.call(request, 'context')) {
                  payload.context = request.context;
                }
                if (type === 'json') {
                  try { payload.response = payload.responseText ? JSON.parse(payload.responseText) : null; } catch (_) {}
                } else if ((type === 'document' || type === 'xml') && typeof DOMParser !== 'undefined') {
                  payload.responseXML = new DOMParser().parseFromString(payload.responseText || '', type === 'xml' ? 'text/xml' : 'text/html');
                  payload.response = payload.responseXML;
                } else {
                  payload.response = payload.responseText;
                }
                return payload;
              };
              const __cmuxFailurePayload = (error) => ({ readyState: 4, status: 0, statusText: String(error), error: String(error) });
              const __cmuxRequestBody = (data) => {
                if (data == null) return undefined;
                if (typeof Blob !== 'undefined' && data instanceof Blob) return data;
                if (typeof File !== 'undefined' && data instanceof File) return data;
                if (typeof FormData !== 'undefined' && data instanceof FormData) return data;
                if (typeof URLSearchParams !== 'undefined' && data instanceof URLSearchParams) return data;
                if (typeof data === 'string') return data;
                if (typeof data === 'object' && typeof URLSearchParams !== 'undefined') {
                  try { return new URLSearchParams(data).toString(); } catch (_) {}
                }
                return String(data);
              };
              const GM_xmlhttpRequest = (details) => {
                const request = details || {};
                const controller = new AbortController();
                const method = String(request.method || 'GET').toUpperCase();
                const headers = request.headers && typeof request.headers === 'object' ? request.headers : {};
                const body = method === 'GET' || method === 'HEAD' ? undefined : __cmuxRequestBody(request.data);
                let settled = false;
                let timeoutID = null;
                const finish = (kind, payload) => {
                  if (settled) return;
                  settled = true;
                  if (timeoutID !== null) clearTimeout(timeoutID);
                  const response = __cmuxApplyResponseType(Object.assign({ readyState: 4 }, payload || {}), request);
                  if (typeof request.onreadystatechange === 'function') request.onreadystatechange(response);
                  if (kind === 'load' && typeof request.onload === 'function') request.onload(response);
                  else if (kind === 'abort' && typeof request.onabort === 'function') request.onabort(response);
                  else if (kind === 'timeout' && typeof request.ontimeout === 'function') request.ontimeout(response);
                  else if (kind === 'error' && typeof request.onerror === 'function') request.onerror(response);
                };
                const abort = () => {
                  controller.abort();
                  finish('abort', __cmuxFailurePayload('aborted'));
                };
                let requestURL;
                try { requestURL = __cmuxResolveURL(request.url || ''); } catch (error) {
                  const payload = __cmuxFailurePayload(error);
                  setTimeout(() => {
                    finish('error', payload);
                  }, 0);
                  return { abort };
                }
                if (!__cmuxCanConnect(requestURL)) {
                  const payload = __cmuxFailurePayload('not_allowed_by_connect');
                  setTimeout(() => {
                    finish('error', payload);
                  }, 0);
                  return { abort };
                }
                if (typeof request.onloadstart === 'function') {
                  request.onloadstart({ readyState: 1, status: 0, statusText: '' });
                }
                const timeout = Number(request.timeout || 0);
                if (Number.isFinite(timeout) && timeout > 0) {
                  timeoutID = setTimeout(() => {
                    controller.abort();
                    finish('timeout', __cmuxFailurePayload('timeout'));
                  }, timeout);
                }
                const nativeReply = __cmuxNativePost({
                  type: 'xmlhttpRequest',
                  url: requestURL,
                  method,
                  headers,
                  data: body == null ? null : String(body),
                  anonymous: !!request.anonymous,
                  responseType: request.responseType == null ? '' : String(request.responseType)
                });
                if (nativeReply) {
                  nativeReply.then((payload) => {
                    const response = Object.assign({ readyState: 4 }, payload || {});
                    finish(response.error ? 'error' : 'load', response);
                  }).catch((error) => {
                    finish('error', __cmuxFailurePayload(error));
                  });
                  return { abort };
                }
                fetch(requestURL, {
                  method,
                  headers,
                  body,
                  credentials: request.anonymous ? 'omit' : 'include',
                  signal: controller.signal
                }).then(async (response) => {
                  if (!__cmuxCanConnect(response.url || requestURL)) {
                    throw new Error('final_url_not_allowed_by_connect');
                  }
                  const responseText = await response.text();
                  const responseHeaders = Array.from(response.headers.entries()).map(([k, v]) => k + ': ' + v).join('\\r\\n');
                  finish('load', {
                    readyState: 4,
                    status: response.status,
                    statusText: response.statusText,
                    finalUrl: response.url,
                    responseText,
                    responseHeaders
                  });
                }).catch((error) => {
                  if (controller.signal.aborted) {
                    finish('abort', __cmuxFailurePayload(error));
                  } else {
                    finish('error', __cmuxFailurePayload(error));
                  }
                });
                return { abort };
              };
              const GM_xmlHttpRequest = GM_xmlhttpRequest;
              const __cmuxXmlHttpRequestPromise = (details) => {
                const request = details || {};
                let handle = null;
                const promise = new Promise((resolve, reject) => {
                  handle = GM_xmlhttpRequest(Object.assign({}, request, {
                    onload: (response) => {
                      if (typeof request.onload === 'function') request.onload(response);
                      resolve(response);
                    },
                    onerror: (response) => {
                      if (typeof request.onerror === 'function') request.onerror(response);
                      reject(response);
                    },
                    onabort: (response) => {
                      if (typeof request.onabort === 'function') request.onabort(response);
                      reject(response);
                    },
                    ontimeout: (response) => {
                      if (typeof request.ontimeout === 'function') request.ontimeout(response);
                      reject(response);
                    }
                  }));
                });
                promise.abort = () => {
                  if (handle && typeof handle.abort === 'function') handle.abort();
                };
                return promise;
              };
              const __cmuxCookieFallbackList = (details) => {
                const filters = details || {};
                return String(document.cookie || '').split(';').map((part) => part.trim()).filter(Boolean).map((part) => {
                  const equals = part.indexOf('=');
                  const name = equals >= 0 ? part.slice(0, equals) : part;
                  const value = equals >= 0 ? part.slice(equals + 1) : '';
                  return {
                    domain: location.hostname,
                    hostOnly: true,
                    httpOnly: false,
                    name: decodeURIComponent(name),
                    path: '/',
                    sameSite: '',
                    secure: location.protocol === 'https:',
                    session: true,
                    value: decodeURIComponent(value)
                  };
                }).filter((cookie) => {
                  if (filters.name && cookie.name !== String(filters.name)) return false;
                  if (filters.domain && cookie.domain !== String(filters.domain).replace(/^\\./, '')) return false;
                  if (filters.path && cookie.path !== String(filters.path)) return false;
                  return true;
                });
              };
              const __cmuxCookieRequest = (type, details, callback) => {
                const requestDetails = details && typeof details === 'object' ? details : {};
                const nativeReply = __cmuxNativePost({ type, details: requestDetails });
                const promise = nativeReply ? nativeReply.then((payload) => {
                  const result = payload || {};
                  if (result.error) throw String(result.error);
                  if (type === 'cookie.list') return Array.isArray(result.cookies) ? result.cookies : [];
                  return undefined;
                }) : new Promise((resolve, reject) => {
                  try {
                    if (type === 'cookie.list') {
                      resolve(__cmuxCookieFallbackList(requestDetails));
                    } else if (type === 'cookie.set') {
                      if (!requestDetails.name) throw new Error('missing_cookie_name');
                      document.cookie = encodeURIComponent(String(requestDetails.name)) + '=' + encodeURIComponent(String(requestDetails.value || ''))
                        + '; path=' + String(requestDetails.path || '/')
                        + (requestDetails.domain ? '; domain=' + String(requestDetails.domain) : '')
                        + (requestDetails.secure ? '; secure' : '')
                        + (requestDetails.sameSite ? '; samesite=' + String(requestDetails.sameSite) : '')
                        + (requestDetails.expirationDate ? '; expires=' + new Date(Number(requestDetails.expirationDate) * 1000).toUTCString() : '');
                      resolve(undefined);
                    } else if (type === 'cookie.delete') {
                      if (!requestDetails.name) throw new Error('missing_cookie_name');
                      document.cookie = encodeURIComponent(String(requestDetails.name)) + '=; path=' + String(requestDetails.path || '/') + '; expires=Thu, 01 Jan 1970 00:00:00 GMT';
                      resolve(undefined);
                    } else {
                      reject(new Error('unsupported_cookie_request'));
                    }
                  } catch (error) {
                    reject(error);
                  }
                });
                promise.then((value) => {
                  if (typeof callback === 'function') {
                    if (type === 'cookie.list') callback(value, null);
                    else callback(undefined);
                  }
                }).catch((error) => {
                  if (typeof callback === 'function') {
                    if (type === 'cookie.list') callback([], String(error));
                    else callback(String(error));
                  }
                });
                return promise;
              };
              const GM_cookie = {
                list: (details, callback) => {
                  if (typeof details === 'function') {
                    callback = details;
                    details = {};
                  }
                  return __cmuxCookieRequest('cookie.list', details || {}, callback);
                },
                set: (details, callback) => __cmuxCookieRequest('cookie.set', details || {}, callback),
                delete: (details, callback) => __cmuxCookieRequest('cookie.delete', details || {}, callback)
              };
              const GM_webRequest = (rules, listener) => {
                __cmuxEnsureWebRequestRegistry();
                return window.__cmuxUserscriptWebRequestRegister(__cmuxUserscript.id, rules || [], listener);
              };
              const __cmuxResourceText = Object.create(null);
              const __cmuxResourceURL = Object.create(null);
              const __cmuxRequireSources = [];
              const __cmuxDataURLForText = (text) => 'data:text/plain;charset=utf-8,' + encodeURIComponent(String(text || ''));
              const __cmuxLoadURL = (url) => new Promise((resolve, reject) => {
                GM_xmlhttpRequest({
                  url,
                  method: 'GET',
                  responseType: 'text',
                  onload: (response) => {
                    if (response.status >= 200 && response.status < 400) {
                      resolve(response.responseText == null ? String(response.response || '') : response.responseText);
                    } else {
                      reject(new Error('HTTP ' + response.status + ' while loading ' + url));
                    }
                  },
                  onerror: reject
                });
              });
              const GM_getResourceText = (name) => __cmuxResourceText[String(name)];
              const GM_getResourceURL = (name) => __cmuxResourceURL[String(name)] || (__cmuxUserscript.resources || {})[String(name)];
              const GM_log = (...args) => console.log(...args);
              const GM_openInTab = (url) => {
                const opened = window.open(__cmuxResolveURL(url || ''), '_blank');
                const handle = {
                  closed: !opened,
                  onclose: null,
                  close: () => {
                    if (!opened || handle.closed) return;
                    try { opened.close(); } catch (_) {}
                    handle.closed = true;
                    if (typeof handle.onclose === 'function') {
                      try { handle.onclose(); } catch (error) { setTimeout(() => { throw error; }, 0); }
                    }
                  }
                };
                if (opened) {
                  const poll = setInterval(() => {
                    if (!opened.closed) return;
                    clearInterval(poll);
                    handle.closed = true;
                    if (typeof handle.onclose === 'function') {
                      try { handle.onclose(); } catch (error) { setTimeout(() => { throw error; }, 0); }
                    }
                  }, 500);
                }
                return handle;
              };
              const GM_download = (details, name) => {
                const request = typeof details === 'string' ? { url: details, name } : (details || {});
                let aborted = false;
                const handle = {
                  abort: () => {
                    aborted = true;
                    if (typeof request.onabort === 'function') request.onabort({ error: 'aborted' });
                  }
                };
                try {
                  const a = document.createElement('a');
                  a.href = __cmuxResolveURL(request.url || '');
                  a.download = String(request.name || request.filename || name || '');
                  a.rel = 'noopener';
                  (document.body || document.documentElement).appendChild(a);
                  a.click();
                  a.remove();
                  if (!aborted && typeof request.onload === 'function') setTimeout(() => request.onload({}), 0);
                } catch (error) {
                  if (typeof request.onerror === 'function') {
                    setTimeout(() => request.onerror({ error: 'not_succeeded', details: String(error) }), 0);
                  }
                }
                return handle;
              };
              const __cmuxDownloadPromise = (details, name) => {
                const request = typeof details === 'string' ? { url: details, name } : (details || {});
                let handle = null;
                const promise = new Promise((resolve, reject) => {
                  handle = GM_download(Object.assign({}, request, {
                    onload: (event) => {
                      if (typeof request.onload === 'function') request.onload(event);
                      resolve(event || {});
                    },
                    onerror: (event) => {
                      if (typeof request.onerror === 'function') request.onerror(event);
                      reject(event);
                    },
                    ontimeout: (event) => {
                      if (typeof request.ontimeout === 'function') request.ontimeout(event);
                      reject(event);
                    },
                    onabort: (event) => {
                      if (typeof request.onabort === 'function') request.onabort(event);
                      reject(event);
                    }
                  }));
                });
                promise.abort = () => {
                  if (handle && typeof handle.abort === 'function') handle.abort();
                };
                return promise;
              };
              const GM_setClipboard = (value, info, callback) => {
                if (typeof info === 'function') {
                  callback = info;
                  info = {};
                }
                const text = String(value == null ? '' : value);
                const promise = (() => {
                  if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
                    return navigator.clipboard.writeText(text);
                  }
                  const area = document.createElement('textarea');
                  area.value = text;
                  area.style.position = 'fixed';
                  area.style.left = '-9999px';
                  document.documentElement.appendChild(area);
                  area.select();
                  document.execCommand('copy');
                  area.remove();
                  return Promise.resolve();
                })();
                promise.then(() => {
                  if (typeof callback === 'function') callback();
                });
                return promise;
              };
              const GM_notification = (details, title, image, onclick) => {
                const request = typeof details === 'string' ? { text: details, title, image, onclick } : (details || {});
                let notification = null;
                let done = false;
                const fireDone = (clicked) => {
                  if (done) return;
                  done = true;
                  if (typeof request.ondone === 'function') request.ondone();
                  if (typeof request.onclose === 'function') request.onclose();
                  if (typeof request.__cmuxResolve === 'function') request.__cmuxResolve(!!clicked);
                };
                if (!('Notification' in window)) {
                  console.info(String(request.title || GM_info.script.name), String(request.text || ''));
                  setTimeout(() => fireDone(false), 0);
                  return undefined;
                }
                const show = () => {
                  notification = new Notification(String(request.title || GM_info.script.name), {
                    body: String(request.text || ''),
                    icon: request.image || request.icon || undefined
                  });
                  notification.onclick = (event) => {
                    if (typeof request.onclick === 'function') request.onclick(event);
                    if (request.url && !(event && event.defaultPrevented)) {
                      try { window.open(__cmuxResolveURL(request.url), '_blank'); } catch (_) {}
                    }
                    fireDone(true);
                  };
                  notification.onclose = () => fireDone(false);
                  if (request.timeout) setTimeout(() => {
                    try { notification.close(); } catch (_) {}
                  }, Number(request.timeout));
                  return notification;
                };
                if (Notification.permission === 'granted') return show();
                if (Notification.permission !== 'denied') {
                  Notification.requestPermission().then((permission) => {
                    if (permission === 'granted') show();
                    else fireDone(false);
                  });
                } else {
                  fireDone(false);
                }
                return undefined;
              };
              const __cmuxNotificationPromise = (details, title, image, onclick) => {
                const request = typeof details === 'string' ? { text: details, title, image, onclick } : Object.assign({}, details || {});
                return new Promise((resolve) => {
                  request.__cmuxResolve = resolve;
                  GM_notification(request);
                });
              };
              const __cmuxAudioListeners = new Set();
              const __cmuxMediaElements = () => Array.from(document.querySelectorAll('audio,video'));
              const __cmuxAudioState = () => {
                const media = __cmuxMediaElements();
                const audible = media.some((element) => !element.paused && !element.ended && !element.muted && Number(element.volume || 0) > 0);
                const muted = media.length > 0 && media.every((element) => element.muted || Number(element.volume || 0) === 0);
                return {
                  isMuted: muted,
                  muteReason: muted ? 'extension' : undefined,
                  isAudible: audible
                };
              };
              const __cmuxNotifyAudioListeners = () => {
                const state = __cmuxAudioState();
                const event = {
                  muted: state.isMuted ? (state.muteReason || 'extension') : false,
                  audible: state.isAudible
                };
                for (const listener of __cmuxAudioListeners) {
                  try { listener(event); } catch (error) { setTimeout(() => { throw error; }, 0); }
                }
              };
              const __cmuxInstallAudioElementListeners = () => {
                for (const element of __cmuxMediaElements()) {
                  if (element.__cmuxUserscriptAudioTracked) continue;
                  try {
                    Object.defineProperty(element, '__cmuxUserscriptAudioTracked', { value: true });
                  } catch (_) {
                    element.__cmuxUserscriptAudioTracked = true;
                  }
                  for (const name of ['play', 'pause', 'volumechange', 'ended']) {
                    element.addEventListener(name, __cmuxNotifyAudioListeners, true);
                  }
                }
              };
              __cmuxInstallAudioElementListeners();
              if (typeof MutationObserver !== 'undefined') {
                new MutationObserver(__cmuxInstallAudioElementListeners).observe(document.documentElement || document, {
                  childList: true,
                  subtree: true
                });
              }
              const GM_audio = {
                setMute: (details, callback) => {
                  const promise = Promise.resolve().then(() => {
                    const muted = !!((details || {}).isMuted);
                    for (const element of __cmuxMediaElements()) element.muted = muted;
                    __cmuxNotifyAudioListeners();
                  });
                  promise.then(() => {
                    if (typeof callback === 'function') callback(undefined);
                  }).catch((error) => {
                    if (typeof callback === 'function') callback(String(error));
                  });
                  return promise;
                },
                getState: (callback) => {
                  const promise = Promise.resolve(__cmuxAudioState());
                  promise.then((state) => {
                    if (typeof callback === 'function') callback(state);
                  });
                  return promise;
                },
                addStateChangeListener: (listener, callback) => {
                  const promise = Promise.resolve().then(() => {
                    if (typeof listener !== 'function') throw new Error('listener must be a function');
                    __cmuxAudioListeners.add(listener);
                  });
                  promise.then(() => {
                    if (typeof callback === 'function') callback(undefined);
                  }).catch((error) => {
                    if (typeof callback === 'function') callback(String(error));
                  });
                  return promise;
                },
                removeStateChangeListener: (listener, callback) => {
                  const promise = Promise.resolve().then(() => {
                    __cmuxAudioListeners.delete(listener);
                  });
                  promise.then(() => {
                    if (typeof callback === 'function') callback(undefined);
                  });
                  return promise;
                }
              };
              const __cmuxTabStorageKey = __cmuxStoragePrefix + '__tab';
              const GM_getTab = (callback) => {
                let tab = {};
                try { tab = JSON.parse(sessionStorage.getItem(__cmuxTabStorageKey) || '{}') || {}; } catch (_) {}
                if (typeof callback === 'function') callback(tab);
                return tab;
              };
              const GM_saveTab = (tab) => {
                sessionStorage.setItem(__cmuxTabStorageKey, JSON.stringify(tab || {}));
              };
              const GM_getTabs = (callback) => {
                const tabs = {};
                tabs[String(location.href || 'page')] = GM_getTab();
                if (typeof callback === 'function') callback(tabs);
                return tabs;
              };
              const __cmuxWindowClose = () => {
                const reply = __cmuxNativePost({ type: 'window.close' });
                if (reply) reply.catch(() => {});
                else {
                  try { __cmuxUnsafeWindow.close(); } catch (_) {}
                }
              };
              const __cmuxWindowFocus = () => {
                const reply = __cmuxNativePost({ type: 'window.focus' });
                if (reply) reply.catch(() => {});
                try { __cmuxUnsafeWindow.focus(); } catch (_) {}
              };
              const __cmuxWindowOverrides = {};
              if (__cmuxHasAnyGrant(['window.close'])) __cmuxWindowOverrides.close = __cmuxWindowClose;
              if (__cmuxHasAnyGrant(['window.focus'])) __cmuxWindowOverrides.focus = __cmuxWindowFocus;
              const __cmuxUserWindow = (() => {
                const keys = Object.keys(__cmuxWindowOverrides);
                if (!keys.length || typeof Proxy !== 'function') return window;
                return new Proxy(window, {
                  get(target, property) {
                    if (Object.prototype.hasOwnProperty.call(__cmuxWindowOverrides, property)) {
                      return __cmuxWindowOverrides[property];
                    }
                    const value = Reflect.get(target, property, target);
                    return typeof value === 'function' ? value.bind(target) : value;
                  },
                  set(target, property, value) {
                    return Reflect.set(target, property, value, target);
                  },
                  has(target, property) {
                    return Object.prototype.hasOwnProperty.call(__cmuxWindowOverrides, property) || property in target;
                  }
                });
              })();
              const GM = { info: GM_info };
              const __cmuxDefineModern = (name, grants, value) => {
                if (__cmuxHasAnyGrant(grants)) GM[name] = value;
              };
              __cmuxDefineModern('getValue', ['GM_getValue', 'GM.getValue'], (key, defaultValue) => Promise.resolve(GM_getValue(key, defaultValue)));
              __cmuxDefineModern('setValue', ['GM_setValue', 'GM.setValue'], (key, value) => __cmuxPromiseReturn(() => GM_setValue(key, value)));
              __cmuxDefineModern('deleteValue', ['GM_deleteValue', 'GM.deleteValue'], (key) => __cmuxPromiseReturn(() => GM_deleteValue(key)));
              __cmuxDefineModern('listValues', ['GM_listValues', 'GM.listValues'], () => Promise.resolve(GM_listValues()));
              __cmuxDefineModern('setValues', ['GM_setValues', 'GM.setValues'], (values) => __cmuxPromiseReturn(() => GM_setValues(values)));
              __cmuxDefineModern('getValues', ['GM_getValues', 'GM.getValues'], (keysOrDefaults) => Promise.resolve(GM_getValues(keysOrDefaults)));
              __cmuxDefineModern('deleteValues', ['GM_deleteValues', 'GM.deleteValues'], (keys) => __cmuxPromiseReturn(() => GM_deleteValues(keys)));
              __cmuxDefineModern('addValueChangeListener', ['GM_addValueChangeListener', 'GM.addValueChangeListener'], (key, callback) => Promise.resolve(GM_addValueChangeListener(key, callback)));
              __cmuxDefineModern('removeValueChangeListener', ['GM_removeValueChangeListener', 'GM.removeValueChangeListener'], (id) => Promise.resolve(GM_removeValueChangeListener(id)));
              __cmuxDefineModern('addStyle', ['GM_addStyle', 'GM.addStyle'], GM_addStyle);
              __cmuxDefineModern('addElement', ['GM_addElement', 'GM.addElement'], GM_addElement);
              __cmuxDefineModern('registerMenuCommand', ['GM_registerMenuCommand', 'GM.registerMenuCommand'], GM_registerMenuCommand);
              __cmuxDefineModern('unregisterMenuCommand', ['GM_unregisterMenuCommand', 'GM.unregisterMenuCommand'], GM_unregisterMenuCommand);
              __cmuxDefineModern('xmlhttpRequest', ['GM_xmlhttpRequest', 'GM_xmlHttpRequest', 'GM.xmlhttpRequest', 'GM.xmlHttpRequest'], __cmuxXmlHttpRequestPromise);
              __cmuxDefineModern('xmlHttpRequest', ['GM_xmlhttpRequest', 'GM_xmlHttpRequest', 'GM.xmlhttpRequest', 'GM.xmlHttpRequest'], __cmuxXmlHttpRequestPromise);
              __cmuxDefineModern('webRequest', ['GM_webRequest', 'GM.webRequest'], GM_webRequest);
              __cmuxDefineModern('openInTab', ['GM_openInTab', 'GM.openInTab'], GM_openInTab);
              __cmuxDefineModern('download', ['GM_download', 'GM.download'], __cmuxDownloadPromise);
              __cmuxDefineModern('setClipboard', ['GM_setClipboard', 'GM.setClipboard'], (value, info) => GM_setClipboard(value, info));
              __cmuxDefineModern('notification', ['GM_notification', 'GM.notification'], __cmuxNotificationPromise);
              __cmuxDefineModern('cookie', ['GM_cookie', 'GM.cookie', 'GM.cookies'], GM_cookie);
              __cmuxDefineModern('cookies', ['GM_cookie', 'GM.cookie', 'GM.cookies'], GM_cookie);
              __cmuxDefineModern('audio', ['GM_audio', 'GM.audio'], GM_audio);
              __cmuxDefineModern('getResourceText', ['GM_getResourceText', 'GM.getResourceText'], GM_getResourceText);
              __cmuxDefineModern('getResourceUrl', ['GM_getResourceURL', 'GM.getResourceURL', 'GM.getResourceUrl'], GM_getResourceURL);
              __cmuxDefineModern('getResourceURL', ['GM_getResourceURL', 'GM.getResourceURL', 'GM.getResourceUrl'], GM_getResourceURL);
              __cmuxDefineModern('log', ['GM_log', 'GM.log'], GM_log);
              __cmuxDefineModern('getTab', ['GM_getTab', 'GM.getTab'], GM_getTab);
              __cmuxDefineModern('saveTab', ['GM_saveTab', 'GM.saveTab'], GM_saveTab);
              __cmuxDefineModern('getTabs', ['GM_getTabs', 'GM.getTabs'], GM_getTabs);
              const __cmuxRunUserSource = () => {
                try {
                  if (__cmuxGrantNone || __cmuxUserscript.unwrap) {
                    try { window.GM_info = GM_info; } catch (_) {}
                    for (const __cmuxRequire of __cmuxRequireSources) {
                      (0, eval)(String(__cmuxRequire.source || '') + '\\n//# sourceURL=' + String(__cmuxRequire.url || 'cmux-userscript-require.js'));
                    }
                    (0, eval)(\(userSourceLiteral) + '\\n//# sourceURL=\(sourceURL)');
                    return;
                  }
                  (function(window, GM, GM_info, unsafeWindow, GM_getValue, GM_setValue, GM_deleteValue, GM_listValues, GM_setValues, GM_getValues, GM_deleteValues, GM_addValueChangeListener, GM_removeValueChangeListener, GM_addStyle, GM_addElement, GM_registerMenuCommand, GM_unregisterMenuCommand, GM_xmlhttpRequest, GM_xmlHttpRequest, GM_webRequest, GM_cookie, GM_audio, GM_openInTab, GM_download, GM_setClipboard, GM_notification, GM_getResourceText, GM_getResourceURL, GM_log, GM_getTab, GM_saveTab, GM_getTabs) {
                    for (const __cmuxRequire of __cmuxRequireSources) {
                      eval(String(__cmuxRequire.source || '') + '\\n//# sourceURL=' + String(__cmuxRequire.url || 'cmux-userscript-require.js'));
                    }
                    \(userSource)
                  }).call(__cmuxUserWindow, __cmuxUserWindow, GM, GM_info, unsafeWindow, __cmuxExpose(GM_getValue, ['GM_getValue', 'GM.getValue']), __cmuxExpose(GM_setValue, ['GM_setValue', 'GM.setValue']), __cmuxExpose(GM_deleteValue, ['GM_deleteValue', 'GM.deleteValue']), __cmuxExpose(GM_listValues, ['GM_listValues', 'GM.listValues']), __cmuxExpose(GM_setValues, ['GM_setValues', 'GM.setValues']), __cmuxExpose(GM_getValues, ['GM_getValues', 'GM.getValues']), __cmuxExpose(GM_deleteValues, ['GM_deleteValues', 'GM.deleteValues']), __cmuxExpose(GM_addValueChangeListener, ['GM_addValueChangeListener', 'GM.addValueChangeListener']), __cmuxExpose(GM_removeValueChangeListener, ['GM_removeValueChangeListener', 'GM.removeValueChangeListener']), __cmuxExpose(GM_addStyle, ['GM_addStyle', 'GM.addStyle']), __cmuxExpose(GM_addElement, ['GM_addElement', 'GM.addElement']), __cmuxExpose(GM_registerMenuCommand, ['GM_registerMenuCommand', 'GM.registerMenuCommand']), __cmuxExpose(GM_unregisterMenuCommand, ['GM_unregisterMenuCommand', 'GM.unregisterMenuCommand']), __cmuxExpose(GM_xmlhttpRequest, ['GM_xmlhttpRequest', 'GM_xmlHttpRequest', 'GM.xmlhttpRequest', 'GM.xmlHttpRequest']), __cmuxExpose(GM_xmlHttpRequest, ['GM_xmlhttpRequest', 'GM_xmlHttpRequest', 'GM.xmlhttpRequest', 'GM.xmlHttpRequest']), __cmuxExpose(GM_webRequest, ['GM_webRequest', 'GM.webRequest']), __cmuxExpose(GM_cookie, ['GM_cookie', 'GM.cookie', 'GM.cookies']), __cmuxExpose(GM_audio, ['GM_audio', 'GM.audio']), __cmuxExpose(GM_openInTab, ['GM_openInTab', 'GM.openInTab']), __cmuxExpose(GM_download, ['GM_download', 'GM.download']), __cmuxExpose(GM_setClipboard, ['GM_setClipboard', 'GM.setClipboard']), __cmuxExpose(GM_notification, ['GM_notification', 'GM.notification']), __cmuxExpose(GM_getResourceText, ['GM_getResourceText', 'GM.getResourceText']), __cmuxExpose(GM_getResourceURL, ['GM_getResourceURL', 'GM.getResourceURL', 'GM.getResourceUrl']), __cmuxExpose(GM_log, ['GM_log', 'GM.log']), __cmuxExpose(GM_getTab, ['GM_getTab', 'GM.getTab']), __cmuxExpose(GM_saveTab, ['GM_saveTab', 'GM.saveTab']), __cmuxExpose(GM_getTabs, ['GM_getTabs', 'GM.getTabs']));
                } catch (error) {
                  setTimeout(() => { throw error; }, 0);
                }
              };
              const __cmuxPrepareUserscript = () => {
                const requireURLs = Array.isArray(__cmuxUserscript.requires) ? __cmuxUserscript.requires : [];
                const resourceEntries = Object.entries(__cmuxUserscript.resources || {});
                let chain = __cmuxHydrateValues();
                for (const url of requireURLs) {
                  chain = chain.then(() => __cmuxLoadURL(url).then((source) => {
                    __cmuxRequireSources.push({ url, source });
                  }));
                }
                for (const [name, url] of resourceEntries) {
                  chain = chain.then(() => __cmuxLoadURL(url).then((text) => {
                    __cmuxResourceText[String(name)] = String(text || '');
                    __cmuxResourceURL[String(name)] = __cmuxDataURLForText(text || '');
                  }).catch(() => {
                    __cmuxResourceText[String(name)] = '';
                    __cmuxResourceURL[String(name)] = String(url || '');
                  }));
                }
                chain.then(__cmuxRunUserSource).catch((error) => {
                  setTimeout(() => { throw error; }, 0);
                });
              };
              __cmuxPrepareUserscript();
            };
        """

        let scheduler: String
        if metadata.runAt == .documentStart {
            scheduler = "__cmuxInvokeUserscript();"
        } else if metadata.runAt == .documentIdle {
            scheduler = """
              const __cmuxRunIdle = () => {
                if ('requestIdleCallback' in window) {
                  requestIdleCallback(__cmuxInvokeUserscript, { timeout: 1500 });
                } else {
                  setTimeout(__cmuxInvokeUserscript, 1);
                }
              };
              if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', __cmuxRunIdle, { once: true });
              } else {
                __cmuxRunIdle();
              }
            """
        } else {
            scheduler = """
              if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', __cmuxInvokeUserscript, { once: true });
              } else {
                __cmuxInvokeUserscript();
              }
            """
        }

        return """
        (() => {
          const __cmuxUserscript = \(payloadLiteral);
          const __cmuxGlobMatches = (pattern, value) => {
            pattern = String(pattern || '');
            value = String(value || '');
            if (pattern === '*') return true;
            const parts = pattern.split('*');
            if (parts.length === 1) return pattern === value;
            let index = 0;
            for (let i = 0; i < parts.length; i++) {
              const part = parts[i];
              if (!part) continue;
              const found = value.indexOf(part, index);
              if (found < 0) return false;
              if (i === 0 && !pattern.startsWith('*') && found !== 0) return false;
              index = found + part.length;
            }
            const last = parts[parts.length - 1] || '';
            return pattern.endsWith('*') || !last || value.endsWith(last);
          };
          const __cmuxMatchPattern = (pattern, href) => {
            try {
              const split = String(pattern || '').split('://');
              if (split.length !== 2) return false;
              const scheme = split[0].toLowerCase();
              const rest = split[1];
              const slash = rest.indexOf('/');
              const host = (slash >= 0 ? rest.slice(0, slash) : rest).toLowerCase();
              const path = slash >= 0 ? rest.slice(slash) : '/';
              const url = new URL(href);
              const urlScheme = url.protocol.replace(':', '').toLowerCase();
              if (scheme === '*') {
                if (urlScheme !== 'http' && urlScheme !== 'https') return false;
              } else if (scheme !== urlScheme) {
                return false;
              }
              if (scheme !== 'file') {
                const urlHost = url.hostname.toLowerCase();
                if (host === '*') {
                } else if (host.startsWith('*.')) {
                  const suffix = host.slice(2);
                  if (urlHost !== suffix && !urlHost.endsWith('.' + suffix)) return false;
                } else if (host !== urlHost) {
                  return false;
                }
              }
              return __cmuxGlobMatches(path, url.pathname || '/');
            } catch (_) {
              return false;
            }
          };
          const __cmuxShouldRun = (href) => {
            const hasPositive = __cmuxUserscript.matches.length > 0 || __cmuxUserscript.includes.length > 0;
            const positive = !hasPositive
              || __cmuxUserscript.matches.some((pattern) => __cmuxMatchPattern(pattern, href))
              || __cmuxUserscript.includes.some((pattern) => __cmuxGlobMatches(pattern, href));
            if (!positive) return false;
            return !__cmuxUserscript.excludeMatches.some((pattern) => __cmuxMatchPattern(pattern, href))
              && !__cmuxUserscript.excludes.some((pattern) => __cmuxGlobMatches(pattern, href));
          };
          const __cmuxEnsureWebRequestRegistry = () => {
            if (window.__cmuxUserscriptWebRequestRegister) return;
            const state = { nextId: 1, entries: new Map() };
            const normalizeArray = (value) => Array.isArray(value) ? value : (value == null ? [] : [value]);
            const selectorMatches = (selector, url) => {
              if (typeof selector === 'string') {
                return __cmuxGlobMatches(selector, url) || __cmuxMatchPattern(selector, url);
              }
              if (!selector || typeof selector !== 'object') return true;
              const includes = normalizeArray(selector.include);
              const matches = normalizeArray(selector.match);
              const excludes = normalizeArray(selector.exclude);
              const positive = (includes.length === 0 && matches.length === 0)
                || includes.some((pattern) => __cmuxGlobMatches(String(pattern), url))
                || matches.some((pattern) => __cmuxMatchPattern(String(pattern), url) || __cmuxGlobMatches(String(pattern), url));
              if (!positive) return false;
              return !excludes.some((pattern) => __cmuxGlobMatches(String(pattern), url));
            };
            const redirectURL = (action, url) => {
              if (!action || typeof action !== 'object') return null;
              if (typeof action.redirect === 'string') return action.redirect;
              if (action.redirect && typeof action.redirect === 'object') {
                try {
                  return String(url).replace(new RegExp(String(action.redirect.from || '')), String(action.redirect.to || ''));
                } catch (_) {
                  return null;
                }
              }
              return null;
            };
            const actionFor = (url) => {
              for (const entry of state.entries.values()) {
                for (const rule of entry.rules) {
                  if (!selectorMatches(rule.selector, url)) continue;
                  const action = typeof rule.action === 'string' ? { cancel: rule.action === 'cancel' } : (rule.action || {});
                  if (action.cancel) return { entry, rule, kind: 'cancel' };
                  const redirected = redirectURL(action, url);
                  if (redirected) return { entry, rule, kind: 'redirect', redirectURL: redirected };
                }
              }
              return null;
            };
            const notify = (match, message, url, description) => {
              if (!match || typeof match.entry.listener !== 'function') return;
              try {
                match.entry.listener(match.kind, message, {
                  rule: match.rule,
                  url,
                  redirect_url: match.redirectURL,
                  description: description || ''
                });
              } catch (error) {
                setTimeout(() => { throw error; }, 0);
              }
            };
            window.__cmuxUserscriptWebRequestRegister = (scriptId, rules, listener) => {
              const id = state.nextId++;
              state.entries.set(id, {
                scriptId: String(scriptId || ''),
                rules: normalizeArray(rules).filter((rule) => rule && typeof rule === 'object'),
                listener
              });
              return () => state.entries.delete(id);
            };
            const originalFetch = window.fetch;
            if (typeof originalFetch === 'function') {
              window.fetch = function(input, init) {
                let url;
                try {
                  url = new URL(typeof input === 'string' ? input : input.url, location.href).href;
                } catch (_) {
                  return originalFetch.apply(this, arguments);
                }
                const match = actionFor(url);
                if (!match) return originalFetch.apply(this, arguments);
                if (match.kind === 'cancel') {
                  notify(match, 'ok', url, '');
                  return Promise.reject(new DOMException('The request was cancelled by GM_webRequest.', 'AbortError'));
                }
                notify(match, 'ok', url, '');
                if (typeof input === 'string') {
                  return originalFetch.call(this, match.redirectURL, init);
                }
                try {
                  return originalFetch.call(this, new Request(match.redirectURL, input), init);
                } catch (_) {
                  return originalFetch.call(this, match.redirectURL, init);
                }
              };
            }
            const OriginalXHR = window.XMLHttpRequest;
            if (typeof OriginalXHR === 'function') {
              const originalOpen = OriginalXHR.prototype.open;
              const originalSend = OriginalXHR.prototype.send;
              OriginalXHR.prototype.open = function(method, url, ...rest) {
                const resolvedURL = new URL(String(url || ''), location.href).href;
                const match = actionFor(resolvedURL);
                if (match && match.kind === 'cancel') {
                  this.__cmuxUserscriptWebRequestCancel = { match, url: resolvedURL };
                  return originalOpen.call(this, method, resolvedURL, ...rest);
                }
                if (match && match.kind === 'redirect') {
                  notify(match, 'ok', resolvedURL, '');
                  return originalOpen.call(this, method, match.redirectURL, ...rest);
                }
                return originalOpen.call(this, method, url, ...rest);
              };
              OriginalXHR.prototype.send = function(...args) {
                if (this.__cmuxUserscriptWebRequestCancel) {
                  const cancel = this.__cmuxUserscriptWebRequestCancel;
                  notify(cancel.match, 'ok', cancel.url, '');
                  this.abort();
                  return;
                }
                return originalSend.apply(this, args);
              };
            }
            const OriginalWebSocket = window.WebSocket;
            if (typeof OriginalWebSocket === 'function') {
              const WrappedWebSocket = function(url, protocols) {
                let resolvedURL;
                try {
                  resolvedURL = new URL(String(url || ''), location.href).href;
                } catch (_) {
                  return protocols === undefined ? new OriginalWebSocket(url) : new OriginalWebSocket(url, protocols);
                }
                const match = actionFor(resolvedURL);
                if (match && match.kind === 'cancel') {
                  notify(match, 'ok', resolvedURL, '');
                  throw new DOMException('The WebSocket was cancelled by GM_webRequest.', 'AbortError');
                }
                if (match && match.kind === 'redirect') {
                  notify(match, 'ok', resolvedURL, '');
                  return protocols === undefined ? new OriginalWebSocket(match.redirectURL) : new OriginalWebSocket(match.redirectURL, protocols);
                }
                return protocols === undefined ? new OriginalWebSocket(url) : new OriginalWebSocket(url, protocols);
              };
              WrappedWebSocket.prototype = OriginalWebSocket.prototype;
              for (const key of ['CONNECTING', 'OPEN', 'CLOSING', 'CLOSED']) {
                try { WrappedWebSocket[key] = OriginalWebSocket[key]; } catch (_) {}
              }
              window.WebSocket = WrappedWebSocket;
            }
          };
          const __cmuxHeaderWebRequestRules = () => {
            const rules = [];
            for (const raw of Array.isArray(__cmuxUserscript.webRequests) ? __cmuxUserscript.webRequests : []) {
              try {
                const parsed = JSON.parse(String(raw || ''));
                if (Array.isArray(parsed)) rules.push(...parsed);
                else if (parsed && typeof parsed === 'object') rules.push(parsed);
              } catch (_) {}
            }
            return rules;
          };
          if (__cmuxUserscript.noframes && window.top !== window) return;
          if (!__cmuxShouldRun(String(location.href || ''))) return;
          const __cmuxInitialWebRequestRules = __cmuxHeaderWebRequestRules();
          const __cmuxNeedsWebRequest = __cmuxInitialWebRequestRules.length > 0
            || (__cmuxUserscript.grants || []).some((grant) => String(grant).toLowerCase() === 'gm_webrequest' || String(grant).toLowerCase() === 'gm.webrequest');
          if (__cmuxNeedsWebRequest) {
            __cmuxEnsureWebRequestRegistry();
            if (__cmuxInitialWebRequestRules.length > 0) {
              window.__cmuxUserscriptWebRequestRegister(__cmuxUserscript.id, __cmuxInitialWebRequestRules, null);
            }
          }
        \(invoke)
        \(scheduler)
        })();
        //# sourceURL=\(sourceURL)
        """
    }

    private func jsonLiteral(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let text = String(data: data, encoding: .utf8),
           text.count >= 2 {
            return String(text.dropFirst().dropLast())
        }
        if let string = value as? String {
            return "\"\(string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return "null"
    }
}

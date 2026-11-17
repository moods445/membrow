import Foundation

/// 与页面交互的两段脚本：登录提交时回传凭据、按需填充已保存凭据。
///
/// 仅做输入框读写，不修改页面内容、不做冻结/快照/比对，也不暴露密码给页面其他脚本。
public enum CredentialScript {
    public static let handlerName = "membrowCredentials"

    /// 注入到动态实例的 documentEnd 脚本：仅在表单提交时读取一次用户名/密码。
    public static let capture = """
    (function () {
      if (window.__membrowCredentialCapture) { return; }
      window.__membrowCredentialCapture = true;

      var userSelectors = [
        'input[autocomplete="username"]',
        'input[type="email"]',
        'input[name*="user" i]',
        'input[name*="email" i]',
        'input[id*="user" i]',
        'input[id*="email" i]',
        'input[type="text"]'
      ];

      function findUsername(form) {
        for (var i = 0; i < userSelectors.length; i++) {
          var element = form.querySelector(userSelectors[i]);
          if (element && element.value) { return element; }
        }
        return null;
      }

      document.addEventListener('submit', function (event) {
        try {
          var form = event.target;
          if (!form || !form.closest) { return; }
          if (form.tagName !== 'FORM') { form = form.closest('form'); }
          if (!form) { return; }
          var password = form.querySelector('input[type="password"]');
          if (!password || !password.value) { return; }
          var username = findUsername(form);
          window.webkit.messageHandlers.\(handlerName).postMessage({
            host: location.hostname,
            username: username ? username.value : '',
            password: password.value
          });
        } catch (error) { }
      }, true);
    })();
    """

    /// 填充脚本：仅当页面存在空的密码框时写入，不覆盖用户已输入的内容。
    public static func fill(username: String, password: String) -> String {
        """
        (function () {
          var password = document.querySelector('input[type="password"]');
          if (!password || password.value) { return false; }
          var username = document.querySelector('input[autocomplete="username"], input[type="email"], input[name*="user" i], input[id*="user" i], input[type="text"]');
          function setValue(element, value) {
            if (!element) { return; }
            var descriptor = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
            if (descriptor && descriptor.set) { descriptor.set.call(element, value); } else { element.value = value; }
            element.dispatchEvent(new Event('input', { bubbles: true }));
            element.dispatchEvent(new Event('change', { bubbles: true }));
          }
          if (username && !username.value) { setValue(username, \(jsonLiteral(username))); }
          setValue(password, \(jsonLiteral(password)));
          return true;
        })();
        """
    }

    /// 用 JSON 编码生成字面量，避免引号、反斜杠、换行把脚本拼坏（或被注入）。
    public static func jsonLiteral(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}

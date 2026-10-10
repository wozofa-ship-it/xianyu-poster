import SwiftUI
import WebKit
import PhotosUI

@main
struct PosterApp: App {
    // 全局共享：同一 processPool + 默认 dataStore，保证两个 webview 共用登录态且持久化
    static let processPool = WKProcessPool()
    var body: some Scene {
        WindowGroup {
            TabView {
                FormWebView()
                    .tabItem { Label("发帖", systemImage: "square.and.pencil") }
                GoofishWebView()
                    .tabItem { Label("闲鱼", systemImage: "fish") }
            }
        }
    }
}

// MARK: - 发帖表单页（本地 HTML）
struct FormWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = PosterApp.processPool
        config.websiteDataStore = .default() // 持久化
        config.userContentController.add(context.coordinator, name: "poster")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        context.coordinator.webView = wv
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate,
                       PHPickerViewControllerDelegate {
        weak var webView: WKWebView?
        var pendingImages: Int = 0

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let dict = message.body as? [String: Any],
                  let action = dict["action"] as? String else { return }
            if action == "pickImages" {
                pendingImages = dict["max"] as? Int ?? 9
                openPicker()
            } else if action == "publish",
                      let data = dict["data"] as? [String: Any] {
                startPublish(data: data)
            }
        }

        // ---- 相册多选 ----
        func openPicker() {
            var cfg = PHPickerConfiguration(photoLibrary: .shared())
            cfg.selectionLimit = max(1, min(pendingImages, 9))
            cfg.filter = .images
            let picker = PHPickerViewController(configuration: cfg)
            picker.delegate = self
            topVC()?.present(picker, animated: true)
        }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            var out: [[String: String]] = []
            let group = DispatchGroup()
            for (i, r) in results.enumerated() {
                group.enter()
                r.itemProvider.loadObject(ofClass: UIImage.self) { obj, _ in
                    defer { group.leave() }
                    guard let img = obj as? UIImage else { return }
                    let scaled = self.downscale(img, maxSide: 1280)
                    if let data = scaled.jpegData(compressionQuality: 0.8) {
                        out.append(["id": "img\(i)_\(Int(Date().timeIntervalSince1970))",
                                    "dataUrl": "data:image/jpeg;base64,\(data.base64EncodedString())"])
                    }
                }
            }
            group.notify(queue: .main) {
                let json = (try? JSONSerialization.data(withJSONObject: out)) ?? Data()
                let str = String(data: json, encoding: .utf8) ?? "[]"
                let esc = str.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "${", with: "\\${")
                self.webView?.evaluateJavaScript("window.__onImagesPicked(JSON.parse(`\(esc)`))", completionHandler: nil)
            }
        }
        func downscale(_ img: UIImage, maxSide: CGFloat) -> UIImage {
            let s = max(img.size.width, img.size.height)
            guard s > maxSide else { return img }
            let scale = maxSide / s
            let size = CGSize(width: img.size.width*scale, height: img.size.height*scale)
            UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
            img.draw(in: CGRect(origin: .zero, size: size))
            let out = UIGraphicsGetImageFromCurrentImageContext() ?? img
            UIGraphicsEndImageContext()
            return out
        }

        // ---- 一键发布 ----
        func startPublish(data: [String: Any]) {
            guard let wv = PublishJob.shared.goofishWebView else {
                // 闲鱼 tab 的 webview 还没建：先提示用户去登录
                webView?.evaluateJavaScript(
                    "window.__publishResult(false,'请先到「闲鱼」页完成登录再发布')", completionHandler: nil)
                return
            }
            // 把表单数据存起来，页面加载完再注入
            PublishJob.shared.start(data: data, webView: wv) { [weak self] ok, msg in
                let m = msg.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "")
                self?.webView?.evaluateJavaScript(
                    "window.__publishResult(\(ok),'\(m)')", completionHandler: nil)
            }
        }

        func topVC() -> UIViewController? {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
        }
    }
}

// MARK: - 闲鱼网页（登录态所在）
struct GoofishWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = PosterApp.processPool
        config.websiteDataStore = .default() // 持久化登录态
        // 允许 file input 拍照/相册
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        context.coordinator.webView = wv
        // 把自己注册给表单页，供发布复用
        PublishJob.shared.goofishWebView = wv
        wv.load(URLRequest(url: URL(string: "https://www.goofish.com")!))
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
    }
}

// MARK: - 发布任务：加载 /publish → 注入 JS 填表 → 上传图片 → 点发布
class PublishJob: NSObject {
    static let shared = PublishJob()
    weak var goofishWebView: WKWebView?
    private var data: [String: Any] = [:]
    private var completion: ((Bool, String) -> Void)?
    private var navObserver: NSKeyValueObservation?

    func start(data: [String: Any], webView: WKWebView,
               completion: @escaping (Bool, String) -> Void) {
        self.data = data
        self.completion = completion
        // 导航到发布页，监听加载完成
        navObserver = webView.observe(\.isLoading, options: [.new]) { [weak self] wv, ch in
            guard let self = self, ch.newValue == false else { return }
            // 再等 1.5s 让 React 渲染表单
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.inject() }
        }
        // 只观察一次
        webView.load(URLRequest(url: URL(string: "https://www.goofish.com/publish")!))
        // 超时保护 60s
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self = self, self.completion != nil else { return }
            self.finish(false, "发布超时，请到闲鱼页手动确认")
        }
    }

    private func inject() {
        guard let wv = goofishWebView, completion != nil else { return }
        navObserver?.invalidate(); navObserver = nil
        let title = esc(data["title"] as? String ?? "")
        let price = esc(data["price"] as? String ?? "")
        let desc = esc(data["desc"] as? String ?? "")
        let cond = data["cond"] as? Int ?? 2
        let images = (data["images"] as? [[String: String]]) ?? []
        let imgJson = (try? JSONSerialization.data(withJSONObject: images)) ?? Data()
        let imgStr = (String(data: imgJson, encoding: .utf8) ?? "[]")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")

        let js = """
        (async function(){
          const log = [];
          const sleep = ms => new Promise(r=>setTimeout(r,ms));
          // --- 标题：第一个 contenteditable（排除描述编辑器）---
          try {
            const editors = [...document.querySelectorAll('[contenteditable="true"]')];
            const descPh = document.querySelector('[data-placeholder*="描述一下"]');
            const titleEl = editors.find(e=>e!==descPh) || editors[0];
            if(titleEl){ titleEl.focus();
              document.execCommand('selectAll',false,null);
              document.execCommand('insertText',false,`\(title)`);
              titleEl.dispatchEvent(new InputEvent('input',{bubbles:true}));
              log.push('标题OK');
            } else log.push('标题框未找到');
          } catch(e){ log.push('标题异常:'+e.message); }
          await sleep(400);
          // --- 价格 ---
          try {
            const p = document.querySelector('input[placeholder="0.00"]');
            if(p){
              const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set;
              setter.call(p, `\(price)`);
              p.dispatchEvent(new Event('input',{bubbles:true}));
              p.dispatchEvent(new Event('change',{bubbles:true}));
              log.push('价格OK');
            } else log.push('价格框未找到');
          } catch(e){ log.push('价格异常:'+e.message); }
          await sleep(400);
          // --- 新旧程度 radio ---
          try {
            const radios = [...document.querySelectorAll('input[type="radio"]')];
            if(radios.length > \(cond)){ radios[\(cond)].click(); log.push('新旧OK'); }
            else log.push('新旧选项未找到('+radios.length+')');
          } catch(e){ log.push('新旧异常:'+e.message); }
          await sleep(400);
          // --- 描述（富文本编辑器）---
          try {
            const d = document.querySelector('[data-placeholder*="描述一下"]');
            if(d){ d.focus();
              document.execCommand('selectAll',false,null);
              document.execCommand('insertText',false,`\(desc)`);
              d.dispatchEvent(new InputEvent('input',{bubbles:true}));
              log.push('描述OK');
            } else log.push('描述框未找到');
          } catch(e){ log.push('描述异常:'+e.message); }
          await sleep(400);
          // --- 图片上传 ---
          try {
            const imgs = JSON.parse(`\(imgStr)`);
            if(imgs.length > 0){
              const fi = document.querySelector('input[type="file"]');
              if(fi){
                const dt = new DataTransfer();
                for(let i=0;i<imgs.length;i++){
                  const blob = await (await fetch(imgs[i].dataUrl)).blob();
                  dt.items.add(new File([blob], imgs[i].name||('img'+i+'.jpg'), {type:'image/jpeg'}));
                }
                fi.files = dt.files;
                fi.dispatchEvent(new Event('change',{bubbles:true}));
                log.push('图片已选'+imgs.length+'张，等待上传…');
                await sleep(6000);
              } else log.push('文件框未找到');
            }
          } catch(e){ log.push('图片异常:'+e.message); }
          // --- 点发布 ---
          try {
            const btn = [...document.querySelectorAll('button')]
              .find(b=>b.textContent.includes('发布') && !b.disabled && b.offsetParent!==null);
            if(btn){ btn.click(); log.push('已点发布'); }
            else log.push('发布按钮未找到/不可点');
          } catch(e){ log.push('发布异常:'+e.message); }
          return log.join('\\n');
        })();
        """
        wv.evaluateJavaScript(js) { [weak self] result, error in
            guard let self = self else { return }
            if let err = error {
                self.finish(false, "JS注入失败: \(err.localizedDescription)")
            } else {
                let detail = (result as? String ?? "").replacingOccurrences(of: "'", with: "’")
                // 给发布留 8s，再回读一次页面状态
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    wv.evaluateJavaScript("document.documentElement.innerHTML.slice(0,3000)") { r2, _ in
                        let html = (r2 as? String ?? "")
                        let ok = html.contains("发布成功") || html.contains("上架成功") || html.contains("我的发布")
                        self.finish(ok, ok ? "发布成功！" : "已提交，详情：\\n\(detail)")
                    }
                }
            }
        }
    }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "`", with: "\\`")
         .replacingOccurrences(of: "${", with: "\\${")
    }
    private func finish(_ ok: Bool, _ msg: String) {
        navObserver?.invalidate(); navObserver = nil
        let cb = completion; completion = nil
        DispatchQueue.main.async { cb?(ok, msg) }
    }
}

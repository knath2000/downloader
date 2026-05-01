// contentScript.js — injects a button on supported pages
(function() {
    if (!window.location.hostname.includes("pmvhaven.com")) return;
    const btn = document.createElement("button");
    btn.textContent = "📥 Send to VidDL";
    btn.style.cssText = [
        "position: fixed; bottom: 16px; right: 16px; z-index: 9999;",
        "background: #007AFF; color: white; border: none; border-radius: 8px;",
        "padding: 10px 16px; font-size: 14px; font-weight: 600;",
        "cursor: pointer; box-shadow: 0 2px 8px rgba(0,0,0,0.3);"
    ].join("");
    btn.addEventListener("click", () => {
        window.open(`pmvdl://extract?url=${encodeURIComponent(window.location.href)}`, "_blank");
    });
    document.body.appendChild(btn);
})();

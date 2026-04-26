// contentScript.js — injected on pmvhaven.com pages
// Adds a small "Send to PMVDL" button overlay on the page

(function () {
    if (!window.location.hostname.includes("pmvhaven.com")) return;

    const btn = document.createElement("button");
    btn.textContent = "📥 Send to PMVDL";
    btn.style.cssText = [
        "position: fixed; bottom: 16px; right: 16px; z-index: 9999;",
        "background: #007AFF; color: white; border: none; border-radius: 8px;",
        "padding: 10px 16px; font-size: 14px; font-weight: 600;",
        "cursor: pointer; box-shadow: 0 2px 8px rgba(0,0,0,0.3);",
    ].join("");

    btn.addEventListener("click", () => {
        const url = window.location.href;
        const encoded = encodeURIComponent(url);
        window.open(`pmvdl://extract?url=${encoded}`, "_blank");
    });

    document.body.appendChild(btn);
})();

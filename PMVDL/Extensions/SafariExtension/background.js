const PMVHAVEN_PATTERN = /^https?:\/\/(www\.)?pmvhaven\.com\//;

browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.action === "extract") {
        const url = sender.tab?.url;
        if (url && PMVHAVEN_PATTERN.test(url)) {
            // Open PMVDL with custom URL scheme
            const encoded = encodeURIComponent(url);
            window.open(`pmvdl://extract?url=${encoded}`, "_blank");
            sendResponse({ success: true, url });
        } else {
            sendResponse({ success: false, error: "Not a PMVHaven page" });
        }
    }
    return true; // Keep message channel open for async response
});

// Inject action button when navigating to pmvhaven
browser.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
    if (changeInfo.status === "complete" && tab.url && PMVHAVEN_PATTERN.test(tab.url)) {
        browser.action.enable(tab.id);
    } else {
        browser.action.disable(tab.id);
    }
});

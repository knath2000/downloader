// background.js — PMVDL Chrome Extension
chrome.action.onClicked.addListener((tab) => {
    if (tab.url && (tab.url.includes("pmvhaven.com") || tab.url.includes("pmvhaven.com"))) {
        const encoded = encodeURIComponent(tab.url);
        chrome.tabs.create({ url: `pmvdl://extract?url=${encoded}` });
    }
});

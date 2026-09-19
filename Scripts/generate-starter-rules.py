#!/usr/bin/env python3
"""Generates the bundled starter content rule list.

WebKit's content-rule regex engine is a restricted subset: it does not support
disjunctions (`a|b`), so every host needs its own rule. Grouping hosts into one
alternation looks tidy and silently fails to compile, which is why this script
exists instead of a hand-written file.

Usage:
    python3 Scripts/generate-starter-rules.py > \
        Packages/BrowsemiumKit/Sources/BrowsemiumEngine/Resources/StarterContentRules.json
"""

import json
import sys

# Ad networks, analytics, session replay, and mobile attribution endpoints.
# These are hostnames (facts), not copied filter lists.
HOSTS = [
    # Ad serving and Google analytics
    "doubleclick.net", "googlesyndication.com", "googleadservices.com",
    "google-analytics.com", "googletagmanager.com", "adservice.google.com",
    # Audience measurement
    "scorecardresearch.com", "quantserve.com", "comscore.com",
    "imrworldwide.com", "nielsen.com",
    # Content recommendation / native ads
    "criteo.com", "criteo.net", "taboola.com", "outbrain.com",
    "revcontent.com", "zedo.com", "adblade.com",
    # Ad exchanges and SSPs
    "pubmatic.com", "rubiconproject.com", "casalemedia.com", "openx.net",
    "appnexus.com", "adnxs.com", "adsrvr.org", "smartadserver.com",
    "sharethrough.com",
    # Retail and video ad networks
    "amazon-adsystem.com", "teads.tv", "spotxchange.com", "indexww.com",
    "districtm.io", "sovrn.com", "lijit.com",
    # Session replay and heatmaps
    "hotjar.com", "hotjar.io", "mouseflow.com", "crazyegg.com",
    "fullstory.com", "smartlook.com", "clarity.ms", "inspectlet.com",
    # Product analytics
    "mixpanel.com", "segment.io", "segment.com", "amplitude.com", "heap.io",
    "heapanalytics.com", "kissmetrics.com", "statcounter.com",
    # Mobile attribution and engagement
    "branch.io", "adjust.com", "appsflyer.com", "kochava.com", "singular.net",
    "mparticle.com", "braze.com", "leanplum.com",
    # Experimentation platforms
    "optimizely.com", "vwo.com", "monetate.net", "abtasty.com",
    "dynamicyield.com",
    # Remaining ad servers
    "adform.net", "adition.com", "adtech.de", "flashtalking.com",
    "innovid.com", "mathtag.com", "tremorhub.com", "yieldmo.com",
]

# Hosts whose own site should keep working when you visit them directly.
SELF_HOSTED = {
    "google.com", "doubleclick.net", "comscore.com", "nielsen.com",
    "criteo.com", "taboola.com", "outbrain.com", "hotjar.com",
    "fullstory.com", "mixpanel.com", "segment.com", "amplitude.com",
}

# Path fragments that are ad or tracking endpoints on any host.
PATHS = ["pagead", "adserver", "adservice", "adsystem", "beacon", "collect",
         "telemetry", "advert", "prebid"]

# Scripts that exist only to instrument the page.
SCRIPTS = ["gtag/js", "analytics.js", "ga.js", "piwik.js", "matomo.js",
           "fbevents.js", "clarity.js"]


def host_rule(host: str) -> dict:
    trigger = {"url-filter": r"^https?://([a-z0-9-]+\.)*" + host.replace(".", r"\.") + "/"}
    unless = sorted({h for h in SELF_HOSTED if host == h or host.endswith("." + h)})
    if unless:
        trigger["unless-domain"] = [f"*{h}" for h in unless]
    return {"trigger": trigger, "action": {"type": "block"}}


def main() -> None:
    rules = [host_rule(host) for host in HOSTS]
    for fragment in PATHS:
        rules.append({
            "trigger": {"url-filter": r"^https?://[^/]+/" + fragment + "/"},
            "action": {"type": "block"},
        })
    for script in SCRIPTS:
        rules.append({
            "trigger": {"url-filter": r"^https?://[^/]+/" + script.replace(".", r"\.") + "$"},
            "action": {"type": "block"},
        })

    for rule in rules:
        filter_value = rule["trigger"]["url-filter"]
        if "|" in filter_value:
            sys.exit(f"WebKit does not support alternation in url-filter: {filter_value}")

    json.dump(rules, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()

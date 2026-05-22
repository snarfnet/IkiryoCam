from __future__ import annotations

import hashlib
import os
import sys
import time
from pathlib import Path

import jwt
import requests


KEY_ID = os.environ.get("ASC_KEY_ID", "WDXGY9WX55")
ISSUER_ID = os.environ.get("ASC_ISSUER_ID", "2be0734f-943a-4d61-9dc9-5d9045c46fec")
P8_PATH = Path(os.environ.get("ASC_P8_PATH", "C:/Users/Windows/Downloads/AuthKey_WDXGY9WX55.p8"))
BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.tokyonasu.ikiryocam")
APP_VERSION = os.environ.get("APP_VERSION", "1.0")
BUILD_NUMBER = os.environ.get("BUILD_NUMBER")
SCREENSHOT_DIR = Path(os.environ.get("SCREENSHOT_DIR", "StoreAssets/screenshots"))
BASE_URL = "https://api.appstoreconnect.apple.com/v1"

SCREENSHOT_GROUPS = [
    ("APP_IPHONE_67", "iphone_67"),
    ("APP_IPHONE_65", "iphone_65"),
    ("APP_IPHONE_55", "iphone_55"),
    ("APP_IPAD_PRO_3GEN_129", "ipad_129"),
]

META = {
    "ja": {
        "description": (
            "生霊カメラは、動画に残像、透明感、顔、手、女の気配、男の気配を重ねて、"
            "不気味な映像に仕上げるホラー動画エフェクトアプリです。\n\n"
            "動画を読み込み、各トリガーの強さを調整するだけで、背後に揺れる霊のような気配を作れます。"
            "完成した動画は保存してシェアできます。\n\n"
            "ログインは不要です。動画処理は端末内で行います。"
        ),
        "keywords": "ホラー,動画,カメラ,霊,生霊,怪談,エフェクト,残像,顔,手",
        "whatsNew": "女の気配、男の気配、手の気配を分けて調整できるようにしました。顔と手の表現も大きく、揺らぎを強めています。",
        "promotionalText": "動画に潜む気配を映し出すホラー動画エフェクト。",
        "marketingUrl": "https://snarfnet.github.io/",
        "supportUrl": "https://snarfnet.github.io/",
    },
    "en-US": {
        "description": (
            "Ikiryo Camera turns your videos into eerie horror clips with spectral trails, transparency, faces, hands, "
            "female presence, and male presence controls.\n\n"
            "Import a video, tune each trigger, and create a drifting apparition effect behind the subject. "
            "Save the finished video and share it when you are done.\n\n"
            "No sign-in is required. Video processing runs on device."
        ),
        "keywords": "horror,video,camera,ghost,effect,apparition,face,hand,trail,scary",
        "whatsNew": "Added separate female, male, and hand presence controls with larger, more human-like faces and hands plus stronger drifting motion.",
        "promotionalText": "Reveal an eerie presence hidden in your videos.",
        "marketingUrl": "https://snarfnet.github.io/",
        "supportUrl": "https://snarfnet.github.io/",
    },
}


def make_token() -> str:
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER_ID, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        P8_PATH.read_text(encoding="utf-8"),
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )


def headers() -> dict[str, str]:
    return {"Authorization": f"Bearer {make_token()}", "Content-Type": "application/json"}


def api(method: str, path: str, **kwargs) -> requests.Response:
    for attempt in range(1, 7):
        response = requests.request(method, BASE_URL + path, headers=headers(), timeout=120, **kwargs)
        if response.status_code not in (401, 429, 500, 502, 503, 504):
            return response
        print(f"Retry {attempt}/6 {method} {path}: {response.status_code}")
        time.sleep(10 * attempt)
    return response


def api_json(method: str, path: str, **kwargs) -> tuple[requests.Response, dict]:
    response = api(method, path, **kwargs)
    try:
        body = response.json()
    except Exception:
        body = {}
    return response, body


def require(response: requests.Response, label: str) -> requests.Response:
    if 200 <= response.status_code < 300:
        return response
    raise RuntimeError(f"{label} failed {response.status_code}: {response.text[:1000]}")


def list_all(path: str) -> list[dict]:
    rows: list[dict] = []
    next_path: str | None = path
    while next_path:
        response, body = api_json("GET", next_path)
        require(response, f"List {path}")
        rows.extend(body.get("data", []))
        next_url = body.get("links", {}).get("next")
        next_path = next_url.split("/v1", 1)[1] if next_url and "/v1" in next_url else None
    return rows


def find_app() -> str:
    response, body = api_json("GET", f"/apps?filter[bundleId]={BUNDLE_ID}&limit=1")
    require(response, "Find app")
    if not body.get("data"):
        raise RuntimeError(f"App not found for bundle id: {BUNDLE_ID}")
    app = body["data"][0]
    attrs = app["attributes"]
    print(f"App: {attrs.get('name')} / {attrs.get('bundleId')} / {app['id']}")
    return app["id"]


def find_or_create_version(app_id: str) -> str:
    versions = list_all(f"/apps/{app_id}/appStoreVersions?filter[platform]=IOS&limit=200")
    for version in versions:
        attrs = version["attributes"]
        if attrs.get("versionString") == APP_VERSION:
            print(f"Version: {APP_VERSION} / {version['id']} / {attrs.get('appStoreState')}")
            return version["id"]
    response, body = api_json(
        "POST",
        "/appStoreVersions",
        json={
            "data": {
                "type": "appStoreVersions",
                "attributes": {"platform": "IOS", "versionString": APP_VERSION},
                "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
            }
        },
    )
    require(response, "Create version")
    print(f"Created version: {body['data']['id']}")
    return body["data"]["id"]


def ensure_localizations(version_id: str) -> list[dict]:
    localizations = list_all(f"/appStoreVersions/{version_id}/appStoreVersionLocalizations?limit=200")
    existing = {item["attributes"]["locale"]: item for item in localizations}
    for locale in META:
        if locale in existing:
            continue
        response, body = api_json(
            "POST",
            "/appStoreVersionLocalizations",
            json={
                "data": {
                    "type": "appStoreVersionLocalizations",
                    "attributes": {"locale": locale},
                    "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}},
                }
            },
        )
        if response.status_code in (200, 201):
            existing[locale] = body["data"]
            print(f"Created localization: {locale}")
        else:
            print(f"Localization {locale}: {response.status_code} {response.text[:300]}")
    return list(existing.values())


def update_metadata(app_id: str, version_id: str) -> None:
    response = api(
        "PATCH",
        f"/apps/{app_id}",
        json={"data": {"type": "apps", "id": app_id, "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}},
    )
    print(f"Content rights: {response.status_code}")

    response = api(
        "PATCH",
        f"/appStoreVersions/{version_id}",
        json={
            "data": {
                "type": "appStoreVersions",
                "id": version_id,
                "attributes": {"copyright": "2026 Tokyo Nasu", "usesIdfa": False, "releaseType": "AFTER_APPROVAL"},
            }
        },
    )
    print(f"Version settings: {response.status_code}")

    for loc in ensure_localizations(version_id):
        locale = loc["attributes"]["locale"]
        meta = META.get(locale, META["en-US"]).copy()
        response = api(
            "PATCH",
            f"/appStoreVersionLocalizations/{loc['id']}",
            json={"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": meta}},
        )
        if response.status_code == 409 and "whatsNew" in meta:
            meta.pop("whatsNew", None)
            response = api(
                "PATCH",
                f"/appStoreVersionLocalizations/{loc['id']}",
                json={"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": meta}},
            )
        print(f"Metadata {locale}: {response.status_code}")

    response, body = api_json("GET", f"/apps/{app_id}/appInfos?limit=10")
    if response.status_code == 200 and body.get("data"):
        app_info_id = body["data"][0]["id"]
        update_app_info(app_info_id)
        update_age_rating(app_info_id)
    ensure_free_price(app_id)


def update_app_info(app_info_id: str) -> None:
    response = api(
        "PATCH",
        f"/appInfos/{app_info_id}",
        json={
            "data": {
                "type": "appInfos",
                "id": app_info_id,
                "relationships": {
                    "primaryCategory": {"data": {"type": "appCategories", "id": "PHOTO_AND_VIDEO"}},
                },
            }
        },
    )
    print(f"Primary category: {response.status_code}")

    response, body = api_json("GET", f"/appInfos/{app_info_id}/appInfoLocalizations?limit=20")
    if response.status_code != 200:
        print(f"App info localizations: {response.status_code}")
        return
    for loc in body.get("data", []):
        locale = loc["attributes"].get("locale")
        subtitle = "動画に潜む気配を映す" if locale == "ja" else "Haunted video effects"
        response = api(
            "PATCH",
            f"/appInfoLocalizations/{loc['id']}",
            json={
                "data": {
                    "type": "appInfoLocalizations",
                    "id": loc["id"],
                    "attributes": {"name": "生霊カメラ", "subtitle": subtitle, "privacyPolicyUrl": "https://snarfnet.github.io/"},
                }
            },
        )
        print(f"App info {locale}: {response.status_code}")


def update_age_rating(app_info_id: str) -> None:
    attrs = {
        "alcoholTobaccoOrDrugUseOrReferences": "NONE",
        "contests": "NONE",
        "gambling": False,
        "gamblingSimulated": "NONE",
        "gunsOrOtherWeapons": "NONE",
        "healthOrWellnessTopics": False,
        "horrorOrFearThemes": "INFREQUENT_OR_MILD",
        "lootBox": False,
        "matureOrSuggestiveThemes": "INFREQUENT_OR_MILD",
        "medicalOrTreatmentInformation": "NONE",
        "messagingAndChat": False,
        "parentalControls": False,
        "profanityOrCrudeHumor": "NONE",
        "sexualContentGraphicAndNudity": "NONE",
        "sexualContentOrNudity": "NONE",
        "unrestrictedWebAccess": False,
        "userGeneratedContent": False,
        "violenceCartoonOrFantasy": "NONE",
        "violenceRealistic": "NONE",
        "violenceRealisticProlongedGraphicOrSadistic": "NONE",
        "advertising": False,
        "ageAssurance": False,
    }
    response = api("PATCH", f"/ageRatingDeclarations/{app_info_id}", json={"data": {"type": "ageRatingDeclarations", "id": app_info_id, "attributes": attrs}})
    print(f"Age rating: {response.status_code}")


def ensure_free_price(app_id: str) -> None:
    response, body = api_json("GET", f"/apps/{app_id}/appPricePoints?filter[territory]=USA&limit=1")
    if response.status_code != 200 or not body.get("data"):
        print(f"Free price point lookup: {response.status_code}")
        return
    local_id = "${usa-free}"
    payload = {
        "data": {
            "type": "appPriceSchedules",
            "relationships": {
                "app": {"data": {"type": "apps", "id": app_id}},
                "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                "manualPrices": {"data": [{"type": "appPrices", "id": local_id}]},
            },
        },
        "included": [
            {
                "type": "appPrices",
                "id": local_id,
                "attributes": {"startDate": None},
                "relationships": {
                    "appPricePoint": {"data": {"type": "appPricePoints", "id": body["data"][0]["id"]}},
                },
            }
        ],
    }
    response = api("POST", "/appPriceSchedules", json=payload)
    print(f"Free price: {response.status_code}")


def ensure_review_detail(version_id: str) -> None:
    attrs = {
        "contactFirstName": "Tokyo",
        "contactLastName": "Nasu",
        "contactPhone": "+1 844 209 0611",
        "contactEmail": "tokyonasu@yahoo.co.jp",
        "demoAccountRequired": False,
        "notes": (
            "No sign-in is required. The app imports a user-selected video and applies local horror effects. "
            "Video processing runs on device. Please import any short video from Photos to test the effect sliders and export flow."
        ),
    }
    response, body = api_json("GET", f"/appStoreVersions/{version_id}/appStoreReviewDetail")
    if response.status_code == 200 and body.get("data"):
        detail_id = body["data"]["id"]
        response = api("PATCH", f"/appStoreReviewDetails/{detail_id}", json={"data": {"type": "appStoreReviewDetails", "id": detail_id, "attributes": attrs}})
        print(f"Review detail updated: {response.status_code}")
        return
    response = api(
        "POST",
        "/appStoreReviewDetails",
        json={"data": {"type": "appStoreReviewDetails", "attributes": attrs, "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}},
    )
    print(f"Review detail created: {response.status_code}")


def upload_screenshots(version_id: str) -> None:
    for loc in ensure_localizations(version_id):
        locale = loc["attributes"]["locale"]
        print(f"Screenshots: {locale}")
        sets = list_all(f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets?limit=200")
        existing = {item["attributes"]["screenshotDisplayType"]: item["id"] for item in sets}
        for display_type, folder in SCREENSHOT_GROUPS:
            files = sorted((SCREENSHOT_DIR / folder).glob("*.png"))
            if not files:
                print(f"  Missing screenshots: {folder}")
                continue
            set_id = existing.get(display_type)
            if not set_id:
                response, body = api_json(
                    "POST",
                    "/appScreenshotSets",
                    json={
                        "data": {
                            "type": "appScreenshotSets",
                            "attributes": {"screenshotDisplayType": display_type},
                            "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}},
                        }
                    },
                )
                require(response, f"Create screenshot set {display_type}")
                set_id = body["data"]["id"]
            for screenshot in list_all(f"/appScreenshotSets/{set_id}/appScreenshots?limit=200"):
                api("DELETE", f"/appScreenshots/{screenshot['id']}")
            for path in files:
                upload_screenshot(set_id, path)


def upload_screenshot(set_id: str, path: Path) -> None:
    data = path.read_bytes()
    checksum = hashlib.md5(data).hexdigest()
    response, body = api_json(
        "POST",
        "/appScreenshots",
        json={
            "data": {
                "type": "appScreenshots",
                "attributes": {"fileName": path.name, "fileSize": len(data)},
                "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}},
            }
        },
    )
    require(response, f"Reserve screenshot {path.name}")
    screenshot_id = body["data"]["id"]
    for operation in body["data"]["attributes"]["uploadOperations"]:
        part_headers = {item["name"]: item["value"] for item in operation["requestHeaders"]}
        start = operation["offset"]
        end = start + operation["length"]
        put_response = requests.put(operation["url"], headers=part_headers, data=data[start:end], timeout=120)
        if put_response.status_code >= 400:
            raise RuntimeError(f"Upload part failed {put_response.status_code}: {put_response.text[:500]}")
    response = api(
        "PATCH",
        f"/appScreenshots/{screenshot_id}",
        json={"data": {"type": "appScreenshots", "id": screenshot_id, "attributes": {"uploaded": True, "sourceFileChecksum": checksum}}},
    )
    print(f"  {path.name}: {response.status_code}")


def wait_for_build(app_id: str) -> str:
    if BUILD_NUMBER:
        query = f"/builds?filter[app]={app_id}&filter[version]={BUILD_NUMBER}&filter[processingState]=VALID&limit=1"
    else:
        query = f"/builds?filter[app]={app_id}&filter[processingState]=VALID&sort=-uploadedDate&limit=1"
    for index in range(90):
        response, body = api_json("GET", query)
        if response.status_code == 200 and body.get("data"):
            build = body["data"][0]
            print(f"Build ready: {build['id']} / {build['attributes'].get('version')}")
            return build["id"]
        print(f"Waiting for build processing... {index + 1}/90")
        time.sleep(30)
    raise RuntimeError("No valid build found")


def assign_build(version_id: str, build_id: str) -> None:
    api("PATCH", f"/builds/{build_id}", json={"data": {"type": "builds", "id": build_id, "attributes": {"usesNonExemptEncryption": False}}})
    response = api("PATCH", f"/appStoreVersions/{version_id}/relationships/build", json={"data": {"type": "builds", "id": build_id}})
    print(f"Build assigned: {response.status_code}")


def submit_for_review(app_id: str, version_id: str) -> None:
    response, body = api_json("POST", "/reviewSubmissions", json={"data": {"type": "reviewSubmissions", "attributes": {"platform": "IOS"}, "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
    if response.status_code == 201:
        submission_id = body["data"]["id"]
    elif response.status_code == 409:
        submissions = list_all(f"/apps/{app_id}/reviewSubmissions?limit=20")
        candidates = [item for item in submissions if item["attributes"].get("state") in ("READY_FOR_REVIEW", "UNRESOLVED_ISSUES")]
        if not candidates:
            raise RuntimeError(f"Review submission conflict: {response.text[:500]}")
        submission_id = candidates[0]["id"]
        print(f"Reusing review submission: {submission_id}")
    else:
        raise RuntimeError(f"Create review submission failed {response.status_code}: {response.text[:800]}")

    response = api(
        "POST",
        "/reviewSubmissionItems",
        json={
            "data": {
                "type": "reviewSubmissionItems",
                "relationships": {
                    "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission_id}},
                    "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}},
                },
            }
        },
    )
    print(f"Review item: {response.status_code}")
    if response.status_code not in (200, 201, 409):
        raise RuntimeError(f"Review item failed {response.status_code}: {response.text[:800]}")

    response = api("PATCH", f"/reviewSubmissions/{submission_id}", json={"data": {"type": "reviewSubmissions", "id": submission_id, "attributes": {"submitted": True}}})
    require(response, "Submit for review")
    print(f"Submitted for review: {response.json()['data']['attributes'].get('state')}")


def main() -> None:
    if not P8_PATH.exists():
        raise RuntimeError(f"ASC key not found: {P8_PATH}")
    app_id = find_app()
    version_id = find_or_create_version(app_id)
    update_metadata(app_id, version_id)
    ensure_review_detail(version_id)
    upload_screenshots(version_id)
    if os.environ.get("PREPARE_APP_ONLY") == "1":
        print("ASC metadata and screenshots are ready.")
        return
    print("Waiting for screenshots to settle...")
    time.sleep(180)
    build_id = wait_for_build(app_id)
    assign_build(version_id, build_id)
    submit_for_review(app_id, version_id)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise

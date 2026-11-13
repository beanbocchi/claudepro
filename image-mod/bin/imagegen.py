#!/usr/bin/env python3
"""Generates one image on the claudepro server and saves it.

The claudepro-image mod runs this with the request as JSON on stdin:
  {"prompt", "output_path", "model", "size"?, "quality"?, "background"?,
   "reference_images"?}
With reference_images it calls /v1/images/edits, else /v1/images/generations.
On success it prints {"path", "bytes", "model", "revised_prompt"?} as JSON.
On failure it prints the reason to stderr and exits 1.

With --list-models it prints the server's image models as a JSON list,
newest first, instead.

The server and key come from the environment Claude Code runs in:
ANTHROPIC_BASE_URL and ANTHROPIC_AUTH_TOKEN (or ANTHROPIC_API_KEY).
"""
import base64
import json
import mimetypes
import os
import sys
import uuid
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

TIMEOUT = 300
FORMATS = {".png": "png", ".jpg": "jpeg", ".jpeg": "jpeg", ".webp": "webp"}


class Failure(Exception):
    pass


def server():
    base = os.environ.get("ANTHROPIC_BASE_URL", "").rstrip("/")
    key = os.environ.get("ANTHROPIC_AUTH_TOKEN") or os.environ.get("ANTHROPIC_API_KEY") or ""
    if not base.startswith(("http://", "https://")):
        raise Failure("ANTHROPIC_BASE_URL is not set to the claudepro server, so there is no image endpoint")
    if not key:
        raise Failure("neither ANTHROPIC_AUTH_TOKEN nor ANTHROPIC_API_KEY is set")
    return base, key


def output_format(path):
    ext = os.path.splitext(path)[1].lower()
    if ext not in FORMATS:
        raise Failure(f"output_path must end in .png, .jpg, .jpeg or .webp, not {ext or 'nothing'}")
    return FORMATS[ext]


def fields(request, fmt):
    out = {"model": request["model"], "prompt": request["prompt"], "output_format": fmt}
    for name in ("size", "quality", "background"):
        if request.get(name):
            out[name] = request[name]
    return out


def multipart(form, images):
    boundary = uuid.uuid4().hex
    parts = []
    for name, value in form.items():
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
        )
    for path in images:
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError as error:
            raise Failure(f"cannot read reference image {path}: {error.strerror}") from None
        mime = mimetypes.guess_type(path)[0] or "application/octet-stream"
        filename = os.path.basename(path).replace('"', "")
        parts.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="image[]"; filename="{filename}"\r\n'
            f"Content-Type: {mime}\r\n\r\n".encode()
            + data
            + b"\r\n"
        )
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def call(url, key, body, content_type):
    req = Request(url, data=body, method="POST", headers={"Authorization": f"Bearer {key}", "Content-Type": content_type})
    try:
        with urlopen(req, timeout=TIMEOUT) as res:
            return json.load(res)
    except HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:500]
        raise Failure(f"the server answered HTTP {error.code}: {detail}") from None
    except URLError as error:
        raise Failure(f"cannot reach {url}: {getattr(error, 'reason', error)}") from None
    except TimeoutError:
        raise Failure(f"no answer from {url} within {TIMEOUT} s") from None
    except json.JSONDecodeError:
        raise Failure("the server answered with something other than JSON") from None


def image_bytes(item):
    if item.get("b64_json"):
        return base64.b64decode(item["b64_json"])
    if item.get("url"):
        try:
            with urlopen(item["url"], timeout=TIMEOUT) as res:
                return res.read()
        except (URLError, OSError) as error:
            raise Failure(f"cannot download the image from {item['url']}: {error}") from None
    raise Failure("the server's answer holds no image")


def generate(request):
    prompt = request.get("prompt")
    path = request.get("output_path")
    if not isinstance(prompt, str) or not prompt.strip():
        raise Failure("prompt is empty")
    if not isinstance(path, str) or not path:
        raise Failure("output_path is empty")
    if not isinstance(request.get("model"), str) or not request["model"]:
        raise Failure("model is empty; ask the person which image model to use")
    fmt = output_format(path)
    refs = request.get("reference_images") or []
    base, key = server()
    form = fields(request, fmt)

    if refs:
        body, content_type = multipart(form, refs)
        answer = call(f"{base}/v1/images/edits", key, body, content_type)
    else:
        answer = call(f"{base}/v1/images/generations", key, json.dumps(form).encode(), "application/json")

    data = answer.get("data") if isinstance(answer, dict) else None
    if not data:
        raise Failure(f"the server's answer holds no image: {json.dumps(answer)[:500]}")
    blob = image_bytes(data[0])

    path = os.path.abspath(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(blob)
    result = {"path": path, "bytes": len(blob), "model": form["model"]}
    if data[0].get("revised_prompt"):
        result["revised_prompt"] = data[0]["revised_prompt"]
    return result


def image_sort_key(model_id):
    """gpt-image-2.5, gpt-image-2.5-flare, gpt-image-2, gpt-image-1.5: newer
    versions first, and a version's plain name before its variants."""
    words = model_id.lower().replace(".", "-").split("-")
    numbers = [int(w) for w in words if w.isdigit() and len(w) < 8]
    major, minor = (numbers + [0, 0])[:2]
    variant = [w for w in words if not w.isdigit() and w not in ("gpt", "image")]
    return (-major, -minor, len(variant), model_id)


def list_models():
    base, key = server()
    req = Request(f"{base}/v1/models", headers={"Authorization": f"Bearer {key}", "Accept": "application/json"})
    try:
        with urlopen(req, timeout=15) as res:
            payload = json.load(res)
    except HTTPError as error:
        raise Failure(f"the server answered HTTP {error.code} for /v1/models") from None
    except (URLError, OSError, json.JSONDecodeError) as error:
        raise Failure(f"cannot read /v1/models: {error}") from None
    ids = {item.get("id") for item in payload.get("data", []) if isinstance(item, dict)}
    return sorted((i for i in ids if isinstance(i, str) and "image" in i.lower()), key=image_sort_key)


def main():
    if sys.argv[1:] == ["--list-models"]:
        try:
            print(json.dumps(list_models()))
        except Failure as error:
            print(str(error), file=sys.stderr)
            sys.exit(1)
        return
    try:
        request = json.load(sys.stdin)
        if not isinstance(request, dict):
            raise Failure("the request is not a JSON object")
        print(json.dumps(generate(request)))
    except json.JSONDecodeError:
        print("the request is not JSON", file=sys.stderr)
        sys.exit(1)
    except Failure as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

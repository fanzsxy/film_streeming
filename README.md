# FilmStream LK21 403 Handling

Replace ONLY `backend/main.py` and `backend/lk21_scraper.py` in your existing GitHub repository. Preserve `backend/requirements.txt`, `backend/sources.json`, Flutter sources, and Android directory. Commit and push; Vercel deploys the backend if linked to this branch.

Change: `/search/{title}` catches LK21 upstream 403/502/503 and responds with `results: []`, `status: source_unavailable`, diagnostic, rather than presenting an opaque HTTP 503. This response means searching was not completed, NOT that the film has no source. `/lk21/latest` continues to emit diagnostic status (such as `upstream_status: 403`). Root `/` displays API pointers. `/resolve` remains unchanged.

IMPORTANT: This patch does not bypass robots.txt / upstream 403, and does not make videos available. Check `https://film-streeming-api.vercel.app/search/Test` after Vercel redeploys. No APK rebuild needed for backend changes. The existing Flutter UI may show an empty result list if it ignores `status`, in which case a future Flutter UI update will be needed to display the specific source-unavailable text.

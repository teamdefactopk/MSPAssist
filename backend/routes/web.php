<?php

use Illuminate\Support\Facades\Route;

/*
| The Flutter web dashboard is built with --base-href /app/ and copied to
| public/app (see docs/deployment-cpanel.md). Real files (JS, assets) are
| served directly by the web server; any other /app/* path is a client-side
| route, so we return the app's index.html.
*/
Route::get('/', fn () => redirect('/app/'));

Route::get('/app/{path?}', function () {
    $index = public_path('app/index.html');
    abort_unless(is_file($index), 404, 'The web app has not been deployed. Run scripts/build_web.sh.');

    return response()->file($index, ['Content-Type' => 'text/html; charset=UTF-8', 'Cache-Control' => 'no-cache']);
})->where('path', '.*');

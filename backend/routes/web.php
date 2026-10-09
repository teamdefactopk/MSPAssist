<?php

use Illuminate\Support\Facades\Route;

// The Flutter web dashboard is deployed as static files under /app (see docs/deployment-cpanel.md).
Route::get('/', fn () => redirect('/app/'));

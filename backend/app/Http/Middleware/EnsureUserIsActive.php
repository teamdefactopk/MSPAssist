<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

/** Rejects requests from deactivated accounts even if they hold a valid token or session. */
class EnsureUserIsActive
{
    public function handle(Request $request, Closure $next): Response
    {
        $user = $request->user();
        if ($user && ! $user->is_active) {
            return response()->json(['message' => 'This account has been deactivated.', 'code' => 'account_inactive'], 403);
        }

        return $next($request);
    }
}

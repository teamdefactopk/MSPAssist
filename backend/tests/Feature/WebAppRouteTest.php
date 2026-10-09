<?php

namespace Tests\Feature;

use Illuminate\Support\Facades\File;
use Tests\TestCase;

class WebAppRouteTest extends TestCase
{
    public function test_client_side_routes_return_the_flutter_index(): void
    {
        $dir = public_path('app');
        $created = ! File::exists($dir.'/index.html');
        if ($created) {
            File::ensureDirectoryExists($dir);
            File::put($dir.'/index.html', '<html><base href="/app/"></html>');
        }
        try {
            $response = $this->get('/app/tickets/12')->assertOk()->assertHeader('Content-Type', 'text/html; charset=UTF-8');
            $this->assertSame(realpath($dir.'/index.html'), $response->baseResponse->getFile()->getRealPath());
            $this->get('/')->assertRedirect('/app/');
        } finally {
            if ($created) {
                File::deleteDirectory($dir);
            }
        }
    }

    public function test_security_headers_are_sent(): void
    {
        $this->getJson('/api/v1/health')->assertOk()
            ->assertHeader('X-Content-Type-Options', 'nosniff')
            ->assertHeader('X-Frame-Options', 'DENY');
    }
}

<?php

namespace Tests\Feature;

use Illuminate\Support\Str;
use Tests\TestCase;

class ReportTest extends TestCase
{
    public function test_all_reports_render_in_all_formats(): void
    {
        $t = $this->createTicket($this->clientAdminA, null, ['subject' => '=HYPERLINK("http://evil")']);
        $this->actingAsUser($this->manager);
        $this->postJson("/api/v1/tickets/{$t['id']}/work-logs", [
            'uuid' => (string) Str::uuid(), 'type' => 'onsite', 'started_at' => now()->subHour()->toIso8601String(), 'minutes' => 45, 'description' => 'Visit',
        ])->assertCreated();

        foreach (['ticket-history', 'technician-activity', 'sla-performance'] as $type) {
            $this->getJson("/api/v1/reports/{$type}")->assertOk()->assertJsonStructure(['data' => ['title', 'period', 'tables']]);
        }
        $monthly = $this->getJson('/api/v1/reports/client-monthly?organization_id='.$this->orgA->id.'&month='.now()->format('Y-m'))->assertOk()->json('data');
        $summary = collect($monthly['tables'][0]['rows'])->pluck('value', 'metric');
        $this->assertSame(1, $summary['Tickets opened']);
        $this->assertSame(0.75, $summary['Support hours delivered']);
        $this->assertSame(1, $summary['Onsite visits']);

        $csv = $this->get('/api/v1/reports/ticket-history?format=csv')->assertOk();
        $this->assertStringContainsString('text/csv', $csv->headers->get('Content-Type'));
        $body = $csv->streamedContent();
        $this->assertStringContainsString("'=HYPERLINK", $body);

        $pdf = $this->get('/api/v1/reports/client-monthly?format=pdf&organization_id='.$this->orgA->id)->assertOk();
        $this->assertStringStartsWith('%PDF', $pdf->getContent());

        $this->getJson('/api/v1/reports/client-monthly')->assertUnprocessable();
        $this->getJson('/api/v1/reports/unknown')->assertNotFound();
    }

    public function test_technician_sees_only_own_activity(): void
    {
        $this->actingAsUser($this->tech);
        $rows = $this->getJson('/api/v1/reports/technician-activity')->assertOk()->json('data.tables.0.rows');
        $this->assertCount(1, $rows);
        $this->assertSame('Tech One', $rows[0]['technician']);
    }
}

<?php

namespace App\Http\Controllers\Api\V1;

use App\Enums\Role;
use App\Http\Controllers\Controller;
use App\Services\AuditLogger;
use App\Services\Reports\ReportService;
use Carbon\CarbonImmutable;
use Dompdf\Dompdf;
use Dompdf\Options;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Response;
use Illuminate\Support\Str;
use Illuminate\Validation\Rule;
use Illuminate\Validation\ValidationException;
use Symfony\Component\HttpFoundation\StreamedResponse;

class ReportController extends Controller
{
    public function __construct(private readonly ReportService $reports) {}

    public function show(Request $request, string $type): JsonResponse|StreamedResponse|Response
    {
        abort_unless(in_array($type, ReportService::TYPES, true), 404);
        $user = $request->user();
        $data = $request->validate([
            'format' => ['nullable', Rule::in(['json', 'csv', 'pdf'])],
            'from' => ['nullable', 'date'],
            'to' => ['nullable', 'date', 'after_or_equal:from'],
            'month' => ['nullable', 'date_format:Y-m'],
            'organization_id' => ['nullable', 'integer', 'exists:organizations,id'],
            'site_id' => ['nullable', 'integer'],
            'user_id' => ['nullable', 'integer'],
        ]);

        // Clients: only their own organization, and not staff-performance reports.
        if ($user->isClient()) {
            abort_unless($user->role === Role::ClientAdmin && in_array($type, ['ticket-history', 'sla-performance', 'client-monthly'], true), 403);
            $data['organization_id'] = $user->organization_id;
        }
        if ($type === 'client-monthly' && empty($data['organization_id'])) {
            throw ValidationException::withMessages(['organization_id' => 'Select a client for the monthly report.']);
        }

        if (! empty($data['month'])) {
            $from = CarbonImmutable::createFromFormat('Y-m', $data['month'])->startOfMonth();
            $to = $from->endOfMonth();
        } else {
            $from = isset($data['from']) ? CarbonImmutable::parse($data['from'])->startOfDay() : now()->toImmutable()->startOfMonth();
            $to = isset($data['to']) ? CarbonImmutable::parse($data['to'])->endOfDay() : now()->toImmutable()->endOfDay();
        }
        abort_if($from->diffInDays($to) > 400, 422, 'Report periods are limited to 400 days.');

        $report = $this->reports->build($type, $user, [
            'from' => $from, 'to' => $to,
            'organization_id' => $data['organization_id'] ?? null,
            'site_id' => $data['site_id'] ?? null,
            'user_id' => $data['user_id'] ?? null,
        ]);
        $format = $data['format'] ?? 'json';
        AuditLogger::log('report.generated', null, ['type' => $type, 'format' => $format, 'period' => $report['period']], $user);

        $filename = Str::slug($type.'-'.$from->format('Ymd').'-'.$to->format('Ymd'));

        return match ($format) {
            'csv' => $this->csv($report, $filename.'.csv'),
            'pdf' => $this->pdf($report, $filename.'.pdf'),
            default => response()->json(['data' => $report]),
        };
    }

    private function csv(array $report, string $filename): StreamedResponse
    {
        return response()->streamDownload(function () use ($report) {
            $out = fopen('php://output', 'w');
            fwrite($out, "\xEF\xBB\xBF"); // UTF-8 BOM for spreadsheet apps
            fputcsv($out, [$report['title']], escape: '');
            fputcsv($out, ['Period', $report['period']], escape: '');
            foreach ($report['tables'] as $table) {
                fputcsv($out, [], escape: '');
                fputcsv($out, [$table['title']], escape: '');
                fputcsv($out, array_values($table['columns']), escape: '');
                foreach ($table['rows'] as $row) {
                    fputcsv($out, array_map(fn ($k) => self::cell($row[$k] ?? null), array_keys($table['columns'])), escape: '');
                }
            }
            fclose($out);
        }, $filename, ['Content-Type' => 'text/csv; charset=UTF-8', 'Cache-Control' => 'private, no-store']);
    }

    /** Neutralise spreadsheet formula injection. */
    public static function cell(mixed $value): string
    {
        $value = (string) ($value ?? '');

        return preg_match('/^[=+\-@\t\r]/', $value) && ! is_numeric($value) ? "'".$value : $value;
    }

    private function pdf(array $report, string $filename): Response
    {
        $options = new Options;
        $options->set('isRemoteEnabled', false);
        $options->set('isPhpEnabled', false);
        $dompdf = new Dompdf($options);
        $dompdf->loadHtml(view('reports.pdf', ['report' => $report, 'generated' => now()])->render());
        $dompdf->setPaper('A4', count($report['tables'][0]['columns'] ?? []) > 8 ? 'landscape' : 'portrait');
        $dompdf->render();

        return response($dompdf->output(), 200, [
            'Content-Type' => 'application/pdf',
            'Content-Disposition' => 'attachment; filename="'.$filename.'"',
            'Cache-Control' => 'private, no-store',
        ]);
    }
}

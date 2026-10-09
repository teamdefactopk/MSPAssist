<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>{{ $report['title'] }}</title>
<style>
    body { font-family: DejaVu Sans, sans-serif; font-size: 9px; color: #1f2933; }
    h1 { font-size: 16px; margin: 0 0 2px; }
    h2 { font-size: 12px; margin: 16px 0 6px; color: #0b5394; }
    .meta { color: #616e7c; margin-bottom: 8px; }
    table { width: 100%; border-collapse: collapse; }
    th { background: #e4ecf7; text-align: left; }
    th, td { border: 1px solid #cbd2d9; padding: 3px 4px; vertical-align: top; }
    tr:nth-child(even) td { background: #f5f7fa; }
</style>
</head>
<body>
<h1>{{ config('app.name') }} — {{ $report['title'] }}</h1>
<div class="meta">Period: {{ $report['period'] }} · Generated {{ $generated->format('Y-m-d H:i') }} UTC</div>
@foreach ($report['tables'] as $table)
    <h2>{{ $table['title'] }}</h2>
    @if (count($table['rows']) === 0)
        <p>No data for this period.</p>
    @else
    <table>
        <thead><tr>@foreach ($table['columns'] as $label)<th>{{ $label }}</th>@endforeach</tr></thead>
        <tbody>
        @foreach ($table['rows'] as $row)
            <tr>@foreach (array_keys($table['columns']) as $key)<td>{{ $row[$key] ?? '' }}</td>@endforeach</tr>
        @endforeach
        </tbody>
    </table>
    @endif
@endforeach
</body>
</html>

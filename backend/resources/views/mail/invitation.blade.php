<x-mail::message>
# Hello {{ $name }},

You have been invited to {{ config('app.name') }} as **{{ $role }}**@if($organization) for **{{ $organization }}**@endif.

<x-mail::button :url="$url">
Accept invitation
</x-mail::button>

This invitation expires on {{ $expires }}. If you were not expecting it, you can ignore this email.

Thanks,<br>
{{ config('app.name') }}
</x-mail::message>

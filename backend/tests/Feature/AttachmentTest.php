<?php

namespace Tests\Feature;

use App\Models\Attachment;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Str;
use Tests\TestCase;

class AttachmentTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();
        Storage::fake('local');
    }

    private function upload(array $ticket, array $extra = [], ?UploadedFile $file = null)
    {
        return $this->post("/api/v1/tickets/{$ticket['id']}/attachments", $extra + [
            'uuid' => (string) Str::uuid(),
            'file' => $file ?? UploadedFile::fake()->image('screen.png', 100, 100),
        ], ['Accept' => 'application/json']);
    }

    public function test_upload_attach_and_authorized_download(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->clientAdminA);
        $att = $this->upload($t)->assertCreated()->json('data');
        $stored = Attachment::find($att['id']);
        Storage::disk('local')->assertExists($stored->path);
        $this->assertStringNotContainsString('.png', $stored->path);

        $this->postJson("/api/v1/tickets/{$t['id']}/messages", [
            'uuid' => (string) Str::uuid(), 'body' => 'See screenshot', 'attachment_uuids' => [$att['uuid']],
        ])->assertCreated()->assertJsonPath('data.attachments.0.id', $att['id']);

        $this->get("/api/v1/attachments/{$att['id']}/download")->assertOk()
            ->assertHeader('X-Content-Type-Options', 'nosniff')
            ->assertHeader('Content-Type', 'application/octet-stream');

        // Other client cannot download it.
        $this->actingAsUser($this->clientAdminB);
        $this->getJson("/api/v1/attachments/{$att['id']}/download")->assertNotFound();
        // Staff can.
        $this->actingAsUser($this->tech);
        $this->get("/api/v1/attachments/{$att['id']}/download")->assertOk();
    }

    public function test_internal_attachments_are_staff_only(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->manager);
        $att = $this->upload($t, ['is_internal' => 1])->assertCreated()->json('data');
        $this->postJson("/api/v1/tickets/{$t['id']}/messages", [
            'uuid' => (string) Str::uuid(), 'body' => 'internal', 'is_internal' => true, 'attachment_uuids' => [$att['uuid']],
        ])->assertCreated();

        $this->actingAsUser($this->clientAdminA);
        $this->getJson("/api/v1/attachments/{$att['id']}/download")->assertNotFound();
        $this->assertCount(0, $this->getJson("/api/v1/tickets/{$t['id']}/attachments")->json('data'));
        $this->upload($t, ['is_internal' => 1])->assertForbidden();
    }

    public function test_unlinked_upload_visible_only_to_uploader(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->clientAdminA);
        $att = $this->upload($t)->json('data');
        $this->actingAsUser($this->manager);
        $this->getJson("/api/v1/attachments/{$att['id']}/download")->assertNotFound();
    }

    public function test_rejects_dangerous_and_oversized_files(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->clientAdminA);
        $php = UploadedFile::fake()->createWithContent('shell.php', '<?php echo "pwned";');
        $this->upload($t, [], $php)->assertUnprocessable()->assertJsonValidationErrors('file');
        // PHP content disguised with an allowed extension is rejected by content sniffing.
        $disguised = UploadedFile::fake()->createWithContent('photo.png', '<?php system($_GET["c"]);');
        $this->upload($t, [], $disguised)->assertUnprocessable();
        $big = UploadedFile::fake()->create('big.pdf', 20000, 'application/pdf');
        $this->upload($t, [], $big)->assertUnprocessable();
    }

    public function test_upload_retry_is_idempotent(): void
    {
        $t = $this->createTicket($this->clientAdminA);
        $this->actingAsUser($this->clientAdminA);
        $uuid = (string) Str::uuid();
        $a = $this->upload($t, ['uuid' => $uuid])->assertCreated()->json('data.id');
        $b = $this->upload($t, ['uuid' => $uuid])->assertOk()->json('data.id');
        $this->assertSame($a, $b);
    }
}

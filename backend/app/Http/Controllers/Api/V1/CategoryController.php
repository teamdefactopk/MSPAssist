<?php

namespace App\Http\Controllers\Api\V1;

use App\Http\Controllers\Controller;
use App\Models\Category;
use App\Services\AuditLogger;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Validation\Rule;

class CategoryController extends Controller
{
    public function index(): JsonResponse
    {
        return response()->json(['data' => Category::orderBy('name')->get(['id', 'name', 'is_active'])]);
    }

    public function store(Request $request): JsonResponse
    {
        abort_unless($request->user()->isManager(), 403);
        $data = $request->validate(['name' => ['required', 'string', 'max:120', 'unique:categories,name'], 'is_active' => ['sometimes', 'boolean']]);
        $category = Category::create($data);
        AuditLogger::log('category.created', $category, $data);

        return response()->json(['data' => $category->only('id', 'name', 'is_active')], 201);
    }

    public function update(Request $request, Category $category): JsonResponse
    {
        abort_unless($request->user()->isManager(), 403);
        $data = $request->validate([
            'name' => ['sometimes', 'string', 'max:120', Rule::unique('categories', 'name')->ignore($category->id)],
            'is_active' => ['sometimes', 'boolean'],
        ]);
        $category->update($data);
        AuditLogger::log('category.updated', $category, $data);

        return response()->json(['data' => $category->only('id', 'name', 'is_active')]);
    }
}

<?php

use App\Http\Controllers\Api\ActivityLogController;
use App\Http\Controllers\Api\AuthController;
use App\Http\Controllers\Api\FcmTokenController;
use App\Http\Controllers\Api\IndoorFarmingAdminController;
use App\Http\Controllers\IncubatorController;
use App\Http\Controllers\IndoorFarmingController;
use Illuminate\Support\Facades\Route;

Route::prefix('v1')->group(function (): void {
    Route::get('/health', function () {
        return response()->json([
            'ok' => true,
            'service' => 'Welcome to endpoint Smart Incubator API',
            'timestamp' => now()->toIso8601String(),
        ]);
    });

    Route::prefix('auth')->group(function (): void {
        Route::post('/register', [AuthController::class, 'register'])->middleware('throttle:5,15');
        Route::post('/login', [AuthController::class, 'login'])->middleware('throttle:10,1');
        Route::get('/sso/start', [AuthController::class, 'ssoStart']);
        Route::get('/sso/callback', [AuthController::class, 'ssoCallback']);
        Route::get('/sso/logout-url', [AuthController::class, 'ssoLogoutUrl']);
        Route::post('/sso/exchange', [AuthController::class, 'ssoExchange']);
        Route::post('/sso/mobile-exchange', [AuthController::class, 'ssoMobileExchange']);

        Route::middleware('api.auth')->group(function (): void {
            Route::get('/me', [AuthController::class, 'me']);
            Route::post('/logout', [AuthController::class, 'logout']);
            Route::get('/roles', [AuthController::class, 'roles']);
            Route::get('/users', [AuthController::class, 'users']);
            Route::patch('/users/{userId}/role', [AuthController::class, 'updateUserRole']);
            Route::patch('/users/{userId}/active', [AuthController::class, 'updateUserActive']);
        });
    });

    Route::prefix('activity-logs')->middleware('api.auth')->group(function (): void {
        Route::get('/', [ActivityLogController::class, 'index']);
        Route::post('/', [ActivityLogController::class, 'store']);
    });

    Route::prefix('notifications')->middleware('api.auth')->group(function (): void {
        Route::post('/token', [FcmTokenController::class, 'store']);
        Route::delete('/token', [FcmTokenController::class, 'destroy']);
    });

    Route::post('/system/activity-logs', [ActivityLogController::class, 'storeSystem'])
        ->middleware('system.activity.key');

    Route::get('/system/sensor-history', [IncubatorController::class, 'systemSensorHistory'])
        ->middleware('system.activity.key');
    Route::get('/system/sensor-history/debug', [IncubatorController::class, 'systemSensorHistoryDebug'])
        ->middleware('system.activity.key');

    Route::prefix('incubator/sync')->middleware('api.auth')->group(function (): void {
        Route::get('/state', [IncubatorController::class, 'state']);
        Route::get('/sensor-history', [IncubatorController::class, 'sensorHistory']);
        Route::post('/plant', [IncubatorController::class, 'upsertPlant']);
        Route::delete('/plant/{id}', [IncubatorController::class, 'deletePlant']);
        Route::post('/manual-schedule', [IncubatorController::class, 'saveManualSchedule']);
        Route::post('/apply-plant', [IncubatorController::class, 'applyPlant']);
        Route::post('/activity', [IncubatorController::class, 'storeWebActivity']);
    });

    Route::prefix('incubator/runtime')->middleware('api.auth')->group(function (): void {
        Route::get('/snapshot', [IncubatorController::class, 'runtimeSnapshot']);
    });

    Route::prefix('indoor-farming')->middleware('api.auth')->group(function (): void {
        Route::get('/config', [IndoorFarmingController::class, 'showConfig']);
        Route::get('/control-access', [IndoorFarmingController::class, 'apiControlAccess']);
        Route::post('/unlock', [IndoorFarmingController::class, 'apiUnlockControls']);
    });

    Route::prefix('admin/indoor-farming')->middleware('api.auth')->group(function (): void {
        Route::get('/access-config', [IndoorFarmingAdminController::class, 'config']);
        Route::post('/pin', [IndoorFarmingAdminController::class, 'savePin']);
        Route::post('/access-grants', [IndoorFarmingAdminController::class, 'storeAccessGrant']);
        Route::delete('/access-grants/{grantId}', [IndoorFarmingAdminController::class, 'destroyAccessGrant']);
    });
});

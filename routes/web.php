<?php

use Illuminate\Support\Facades\Route;
use App\Http\Controllers\IncubatorController;
use App\Http\Controllers\IndoorFarmingController;
use App\Http\Controllers\NutrimixController;
use App\Http\Controllers\ProfileController;
use App\Http\Controllers\RolePortalController;

// Rute autentikasi (login, register, logout, dll.) dari Breeze
require __DIR__ . '/auth.php';

// Guest: root selalu ke login
Route::get('/', function () {
    return redirect()->route('login');
})->middleware('guest');

// Semua rute di bawah ini hanya bisa diakses jika sudah login
Route::middleware(['auth'])->group(function () {
    Route::get('/home', [RolePortalController::class, 'dashboard'])->name('home');
    Route::get('/super-admin/dashboard', [RolePortalController::class, 'superAdminDashboard'])->name('super_admin.dashboard');
    Route::get('/admin/dashboard', [RolePortalController::class, 'adminDashboard'])->name('admin.dashboard');
    Route::get('/user/dashboard', [RolePortalController::class, 'userDashboard'])->name('user.dashboard');

    // Alias dashboard
    Route::get('/dashboard', function () {
        return redirect()->route('home');
    })->name('dashboard');

    // Halaman portal utama VitaRoot
    Route::get('/portal', [RolePortalController::class, 'portal'])->name('portal');

    // Role pages (samakan dengan mobile apps)
    Route::get('/super-admin/users', [RolePortalController::class, 'superAdminUsers'])->name('super_admin.users');
    Route::patch('/super-admin/users/{user}/role', [RolePortalController::class, 'updateUserRole'])->name('super_admin.users.update_role');
    Route::get('/admin/users', [RolePortalController::class, 'adminUsers'])->name('admin.users');
    Route::patch('/admin/users/{user}/active', [RolePortalController::class, 'updateUserActive'])->name('admin.users.update_active');
    Route::get('/admin/activity-logs', [RolePortalController::class, 'adminActivityLogs'])->name('admin.activity_logs');
    Route::get('/admin/temperature-logs', [RolePortalController::class, 'adminTemperatureLogs'])->name('admin.temperature_logs');
    Route::get('/user/profile', [RolePortalController::class, 'userProfile'])->name('user.profile');

    // Halaman Incubator
    Route::get('/incubator', [IncubatorController::class, 'index'])->name('incubator');
    Route::get('/incubator/sync/state', [IncubatorController::class, 'state'])->name('incubator.sync.state');
    Route::get('/incubator/runtime/snapshot', [IncubatorController::class, 'runtimeSnapshot'])->name('incubator.runtime.snapshot');
    Route::post('/incubator/sync/plant', [IncubatorController::class, 'upsertPlant'])->name('incubator.sync.plant.upsert');
    Route::delete('/incubator/sync/plant/{id}', [IncubatorController::class, 'deletePlant'])->name('incubator.sync.plant.delete');
    Route::post('/incubator/sync/manual-schedule', [IncubatorController::class, 'saveManualSchedule'])->name('incubator.sync.schedule.manual');
    Route::post('/incubator/sync/apply-plant', [IncubatorController::class, 'applyPlant'])->name('incubator.sync.plant.apply');
    Route::post('/incubator/sync/activity', [IncubatorController::class, 'storeWebActivity'])->name('incubator.sync.activity.store');
    Route::get('/incubator/sync/sensor-history', [IncubatorController::class, 'sensorHistory'])->name('incubator.sync.sensor_history');
    Route::get('/incubator/activity-logs', [IncubatorController::class, 'activityLogsPage'])->name('incubator.activity_logs_page');
    Route::post('/incubator/sync/command', [IncubatorController::class, 'sendCommand'])->name('incubator.sync.command');

    // Halaman Nutrimix
    Route::get('/nutrimix', [NutrimixController::class, 'index'])->name('nutrimix');
    Route::get('/indoor-farming', [IndoorFarmingController::class, 'index'])->name('indoor_farming');
    Route::get('/indoor-farming/config', [IndoorFarmingController::class, 'showConfig'])->name('indoor_farming.config.show');
    Route::post('/indoor-farming/config', [IndoorFarmingController::class, 'saveConfig'])->name('indoor_farming.config.save');
    Route::post('/indoor-farming/unlock', [IndoorFarmingController::class, 'unlockControls'])->name('indoor_farming.unlock');
    Route::post('/indoor-farming/activity', [IndoorFarmingController::class, 'storeWebActivity'])->name('indoor_farming.activity.store');
    Route::get('/indoor-farming/activity-logs', [IndoorFarmingController::class, 'activityLogsPage'])->name('indoor_farming.activity_logs_page');
    Route::get('/indoor-farming/research', [IndoorFarmingController::class, 'research'])->name('indoor_farming.research');

    // Halaman Alat Lainnya
    Route::get('/alat-lainnya', [RolePortalController::class, 'toolsIndex'])->name('tools');
    Route::post('/alat-lainnya/indoor-farming/pin', [RolePortalController::class, 'saveIndoorFarmingPin'])->name('tools.indoor_farming.pin.save');
    Route::post('/alat-lainnya/indoor-farming/access-grants', [RolePortalController::class, 'storeIndoorFarmingAccessGrant'])->name('tools.indoor_farming.access_grants.store');
    Route::delete('/alat-lainnya/indoor-farming/access-grants/{grant}', [RolePortalController::class, 'destroyIndoorFarmingAccessGrant'])->name('tools.indoor_farming.access_grants.destroy');
    Route::get('/monitoring-area', [RolePortalController::class, 'monitoringArea'])->name('tools.monitoring_area');
    Route::get('/monitoring-area/{areaId}', [RolePortalController::class, 'monitoringAreaDetail'])
        ->whereIn('areaId', ['bc1', 'bc2', 'atc'])
        ->name('tools.monitoring_area.detail');
    Route::post('/monitoring-area/activity', [RolePortalController::class, 'storeFrontendActivity'])->name('tools.monitoring_area.activity');

    // Profil pengguna (Breeze)
    Route::get('/profile', [ProfileController::class, 'edit'])->name('profile.edit');
    Route::patch('/profile', [ProfileController::class, 'update'])->name('profile.update');
    Route::delete('/profile', [ProfileController::class, 'destroy'])->name('profile.destroy');
});

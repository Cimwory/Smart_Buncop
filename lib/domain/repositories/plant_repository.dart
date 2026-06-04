/// Transport-agnostic plant repository interface.
/// Plants are managed via the Laravel API (PostgreSQL) and synced to devices via MQTT.
abstract class PlantRepository {
  Stream<Map<String, dynamic>> plantStream();
  Stream<Map<String, dynamic>?> plantTempConfig(String id);

  Future<void> addPlant(Map<String, dynamic> data);
  Future<void> updatePlant(String id, Map<String, dynamic> data);
  Future<void> deletePlant(String id);

  Future<Map<String, dynamic>?> getTempOptimal(String plantId);
  Future<Map<String, dynamic>?> getPlantById(String plantId);
}

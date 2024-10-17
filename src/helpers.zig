const std = @import("std");

/// Simple ModelFromSql and ModelToSql functions for models which have the same table definition.
pub fn TableModel(comptime Model: type, comptime TableShape: type) type {
	// Get fields of the model, which must be the same as the table shape.
	const fields = std.meta.fields(Model);

	return struct {
		/// Simply copy all fields from model to table.
		pub fn copyModelToTable(_model: Model) !TableShape {
			var _table: TableShape = undefined;
			inline for (fields) |modelField| {
				// Copy each field of the model to the table.
				@field(_table, modelField.name) = @field(_model, modelField.name);
			}
			return _table;
		}

		/// Simply copy all fields from table to model.
		pub fn copyTableToModel(_table: TableShape) !Model {
			var _model: Model = undefined;
			inline for (fields) |tableField| {
				// Copy each field of the table to the model.
				@field(_model, tableField.name) = @field(_table, tableField.name);
			}
			return _model;
		}
	};
}

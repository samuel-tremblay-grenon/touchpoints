class CreateServices < ActiveRecord::Migration[5.2]
  def change
    create_table :services do |t|
      t.string :name
      t.text :description
      t.integer :user_id
      t.string :service_manager

      t.timestamps
    end
  end
end

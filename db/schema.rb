# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# Note that this schema.rb definition is the authoritative source for your
# database schema. If you need to create the application database on another
# system, you should be using db:schema:load, not running all the migrations
# from scratch. The latter is a flawed and unsustainable approach (the more migrations
# you'll amass, the slower it'll run and the greater likelihood for issues).
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema.define(version: 2020_03_26_115249) do

  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "execution_environments", id: :serial, force: :cascade do |t|
    t.string "docker_image", limit: 255
    t.string "name", limit: 255
    t.datetime "created_at"
    t.datetime "updated_at"
    t.string "run_command", limit: 255
    t.string "test_command", limit: 255
    t.string "testing_framework", limit: 255
    t.text "help"
    t.string "exposed_ports", limit: 255
    t.integer "permitted_execution_time"
    t.integer "user_id"
    t.string "user_type", limit: 255
    t.integer "pool_size"
    t.integer "file_type_id"
    t.integer "memory_limit"
    t.boolean "network_enabled"
  end
end

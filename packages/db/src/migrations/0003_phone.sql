CREATE TABLE "phone_codes" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" uuid NOT NULL,
	"phone_key" varchar(64) NOT NULL,
	"code_hash" varchar(64) NOT NULL,
	"attempts" integer DEFAULT 0 NOT NULL,
	"expires_at" timestamp NOT NULL,
	"used_at" timestamp,
	"created_at" timestamp DEFAULT now() NOT NULL,
	CONSTRAINT "phone_codes_attempts" CHECK ("phone_codes"."attempts" >= 0)
);
--> statement-breakpoint
ALTER TABLE "users" ADD COLUMN "phone_key" varchar(64);--> statement-breakpoint
ALTER TABLE "phone_codes" ADD CONSTRAINT "phone_codes_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "phone_codes_user" ON "phone_codes" USING btree ("user_id");--> statement-breakpoint
ALTER TABLE "users" ADD CONSTRAINT "users_phone_key_unique" UNIQUE("phone_key");
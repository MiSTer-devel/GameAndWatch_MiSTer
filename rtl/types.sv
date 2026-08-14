package types;
  typedef struct {
    // Main config
    reg [7:0]  format_version;
    reg [7:0]  feature_flags;
    reg        extension_directory_valid;
    reg        hmc_descriptor_valid;
    reg        crt_image_descriptor_valid;
    reg        crt_mask_descriptor_valid;
    reg [15:0] crt_mask_length;
    reg        crt_image_payload_valid;
    reg        crt_mask_payload_valid;
    reg        player_two_metadata_valid;
    reg [39:0] player_two_mask;
    reg [7:0]  mpu;
    reg [7:0]  screen_config;
    reg [11:0] screen_width;
    reg [11:0] screen_height;

    // Input config
    reg [31:0] input_s0_config;
    reg [31:0] input_s1_config;
    reg [31:0] input_s2_config;
    reg [31:0] input_s3_config;
    reg [31:0] input_s4_config;
    reg [31:0] input_s5_config;
    reg [31:0] input_s6_config;
    reg [31:0] input_s7_config;

    reg [7:0] input_b_config;
    reg [7:0] input_ba_config;
    reg [7:0] input_acl_config;

    reg [3:0] grounded_port_config;
  } system_config;
endpackage

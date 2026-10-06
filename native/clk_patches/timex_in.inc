				// Timex: lectura de $FF (último valor escrito); TS2068: $F4 y $F6 (AY; con el registro
				// 14 elegido, los joysticks: A8 = joystick 1, A9 = joystick 2, activos a 0).
				if constexpr (is_timex) {
					if((address & 0xff) == 0xff) {
						did_match = true;
						*cycle.value = timex_ff_;
					}
				}
				if constexpr (Model::TS2068 == model) {
					switch(address & 0xff) {
						default: break;
						case 0xf4:
							did_match = true;
							*cycle.value = timex_f4_;
						break;
						case 0xf6:
							did_match = true;
							update_audio();
							*cycle.value = (ts_ay_register_ & 0x0f) == 14 ?
								ts2068_joysticks(address) : GI::AY38910::Utility::read(ay_);
						break;
					}
				}


				// Timex (parche de Easy Spectrum, timex_machine.inc): $FF = modo de pantalla (b0-5),
				// sin interrupción (b6) y banco de la MMU (b7). TS2068: $F4 MMU horizontal y el AY
				// en $F5 (registro) / $F6 (dato). Decodificación por el byte bajo completo.
				if constexpr (is_timex) {
					if((address & 0xff) == 0xff) timex_write_ff(*cycle.value);
				}
				if constexpr (Model::TS2068 == model) {
					switch(address & 0xff) {
						default: break;
						case 0xf4:
							timex_f4_ = *cycle.value;
							update_memory_map();
							update_video_base();
						break;
						case 0xf5:
							update_audio();
							ts_ay_register_ = *cycle.value;
							GI::AY38910::Utility::select_register(ay_, *cycle.value);
						break;
						case 0xf6:
							update_audio();
							GI::AY38910::Utility::write_data(ay_, *cycle.value);
						break;
					}
				}


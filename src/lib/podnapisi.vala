using Archive;

namespace Submarine {

	private class PodnapisiServer : SubtitleServer {
		private Soup.SessionSync session;
		private string session_token;

		private const string XMLRPC_URI = "http://ssp.podnapisi.net:8000/RPC2";
		private const string DOWNLOAD_URI = "http://www.podnapisi.net/static/podnapisi/";

		private Gee.HashSet<string> supported_languages;
		private Gee.HashMap<string, int> language_ids;
		private Gee.HashSet<string> selected_languages;

		construct {
			this.info = ServerInfo("Podnapisi",
					"http://www.podnapisi.net/",
					"pn");
		}

		private bool get_supported_languages() {
			HashTable<string,Value?> vh;

			this.supported_languages = new Gee.HashSet<string>();
			this.language_ids = new Gee.HashMap<string, int>();

			var message = Soup.XMLRPC.request_new (XMLRPC_URI,
				"supportedLanguages",
				typeof(string), this.session_token);

			if(XMLRPC.call(this.session, message, out vh) && (int)vh.lookup("status") == 200) {
				unowned ValueArray va = (ValueArray) vh.lookup("languages");

				foreach(Value vresult in va) {
					unowned ValueArray result = (ValueArray)vresult;

					this.supported_languages.add((string)result.get_nth(1));
					this.language_ids.set((string)result.get_nth(1),
							(int)result.get_nth(0));
				}

				return true;
			}

			return false;
		}

		private bool filter_languages(Gee.Collection<string> languages) {
			HashTable<string,Value?> vh;

			if(this.supported_languages == null) {
				this.get_supported_languages();
			}

			var languages_set = new Gee.HashSet<string>();

			foreach(var language in languages) {
				var language_info = get_language_info(language);

				//podnapisi.net supports only short codes
				if(language_info.short_code != null && language_info.short_code in supported_languages) {
					languages_set.add(language_info.short_code);
				}
			}

			if(!languages_set.is_empty) {
				var update = false;
				if(this.selected_languages == null || languages_set.size != this.selected_languages.size) {
					update = true;
				} else {
					foreach(var language in languages_set) {
						if(!(language in this.selected_languages)) {
							update = true;
							break;
						}
					}
				}

				if(update) {
					var languages_array = new ValueArray(0);
					foreach(var language in languages_set) {
						languages_array.append(this.language_ids[language]);
					}

					var message = Soup.XMLRPC.request_new (XMLRPC_URI,
							"setFilters",
							typeof(string), this.session_token,
							typeof(bool), true,
							typeof(ValueArray), languages_array,
							typeof(bool), false);

					if(XMLRPC.call(this.session, message, out vh) && (int)vh.lookup("status") == 200) {
						this.selected_languages = languages_set;
						return true;
					}
				} else {
					return true;
				}
			}

			return false;
		}

		private uint64 file_size(File file) throws Error {
			var file_info = file.query_info("*", FileQueryInfoFlags.NONE);
			return file_info.get_size();
		}

		private uint64 file_hash(File file) throws Error,IOError {
			uint64 hash, size;

			//get filesize and add it to hash
			size = this.file_size(file);
			hash = size;

			//add first 64kB of file to hash
			var dis = new DataInputStream(file.read());
			dis.set_byte_order(DataStreamByteOrder.LITTLE_ENDIAN);
			for(int i=0; i<65536/sizeof(uint64); i++) {
				hash += dis.read_uint64();
			}
			//add last 64kB of file to hash
			dis = new DataInputStream(file.read());
			dis.set_byte_order(DataStreamByteOrder.LITTLE_ENDIAN);
			dis.skip((size_t)(size - 65536));
			for(int i=0; i<65536/sizeof(uint64); i++) {
				hash += dis.read_uint64();
			}

			return hash;
		}

		private bool inflate_subtitle(uint8[] data, out string format, out string inflated_data) {
			var archive = new Archive.Read();

			archive.support_format_zip();

			if(archive.open_memory(data, data.length) == Archive.Result.OK) {
				weak Archive.Entry e;

				while(archive.next_header(out e) == Archive.Result.OK) {
					if (!Posix.S_ISDIR(e.mode())) {
						inflated_data = string.nfill((size_t)e.size(), ' ');
						archive.read_data(inflated_data.data, inflated_data.data.length);

						format = e.pathname().substring(e.pathname().last_index_of(".")+1);

						return true;
					}
				}
			}

			return false;
		}

		public override bool connect() {
			const string username = "submarine";
			const string password = "password";
			HashTable<string,Value?> vh;
			this.session = new Soup.SessionSync();

			var message = Soup.XMLRPC.request_new (XMLRPC_URI,
					"initiate",
					typeof(string), "submarine");

			if(XMLRPC.call(this.session, message, out vh) && (int)vh.lookup("status") == 200) {
				var nonce = (string)(vh.lookup("nonce"));
				this.session_token = (string)(vh.lookup("session"));

				var formatted_password = Checksum.compute_for_string(ChecksumType.SHA256, 
						Checksum.compute_for_string(ChecksumType.MD5, password) + nonce);

				message = Soup.XMLRPC.request_new (XMLRPC_URI,
						"authenticate",
						typeof(string), this.session_token,
						typeof(string), username,
						typeof(string), formatted_password);

				if(XMLRPC.call(this.session, message, out vh) && (int)(vh.lookup("status")) == 200) {
					return true;
				}
			}

			return false;
		}

		public override void disconnect() {
		}

		//Note: search() not implemented, because there is minimal improvement over search_multiple()

		public override Gee.MultiMap<File, Subtitle> search_multiple(Gee.Collection<File> files, Gee.Collection<string> languages) {
			var subtitles_found_map = new Gee.HashMultiMap<File, Subtitle>();
			var requests = new Gee.ArrayList<Value?>();
			var hash_file = new Gee.HashMap<string, File>();

			//maximum response results is 500
			const int MAX = 500;
			//assume 5 hits per subtitle
			const int HITS = 5;

			if(this.filter_languages(languages)) {
				foreach (var file in files) {
					try {
						string hash = "%016llx".printf(this.file_hash(file));

						requests.add(hash);

						hash_file.set(hash, file);
					} catch(Error e) {}
				}

				SubtitleServer.BatchRequestMethod request_method = (request_batch) => {
					var values = new ValueArray(request_batch.size);

					foreach(var request in request_batch) {
						values.append(request);
					}

					var message = Soup.XMLRPC.request_new (XMLRPC_URI,
							"search",
							typeof(string), this.session_token,
							typeof(ValueArray), values);

					Value v;
					if(XMLRPC.call(this.session, message, out v) && (int)((HashTable<string,Value?>)v).lookup("status") == 200) {
						return v;
					}

					return null;
				};

				SubtitleServer.BatchResponseMethod response_method = (response) => {
					HashTable<string,Value?> vh = (HashTable<string,Value?>)response;
					int results = 0;

					if((int)((HashTable<string,Value?>)vh.lookup("results")).size() > 0) {
						foreach(string hash in ((HashTable<string,Value?>)vh.lookup("results")).get_keys()) {
							unowned ValueArray va = (ValueArray) ((HashTable<string,Value?>)((HashTable<string,Value?>)vh.lookup("results")).lookup(hash)).lookup("subtitles");

							foreach(Value vresult in va) {
								HashTable<string,Value?> result = (HashTable<string,Value?>)vresult;

								Subtitle subtitle = new Subtitle(this.info, result);
								subtitle.format = "";
								subtitle.language = (string)result.lookup("lang");
								subtitle.rating = (int)result.lookup("rating")*2;
								subtitles_found_map.set(hash_file[hash], subtitle);
								results++;
							}
						}
					}

					return results;
				};

				this.batch_process(requests, request_method, response_method, MAX/HITS, MAX);
			}

			return subtitles_found_map;
		}

		public override Subtitle? download(Subtitle subtitle) {
			var requests = new ValueArray(0);
			HashTable<string,Value?> vh;

			HashTable<string,Value?> server_data = (HashTable<string,Value?>)subtitle.server_data;
			requests.append(server_data.lookup("id"));

			var message = Soup.XMLRPC.request_new (XMLRPC_URI,
					"download",
					typeof(string), this.session_token,
					typeof(ValueArray), requests);

			if(XMLRPC.call(this.session, message, out vh) &&
			   (int)vh.lookup("status") == 200 &&
			   ((ValueArray)vh.lookup("names")).get_nth(0) != null) {
				HashTable<string,Value?> result = (HashTable<string,Value?>)((ValueArray)vh.lookup("names")).get_nth(0);

				message = new Soup.Message("GET", DOWNLOAD_URI + (string)result.lookup("filename"));

				if(this.session.send_message(message) == 200) {
					string data;
					string format;

					if(this.inflate_subtitle(message.response_body.data, out format, out data)) {
						subtitle.format = format;
						subtitle.data = data;

						return subtitle;
					}
				}
			}

			return null;
		}

		//Note: download_multiple() not implemented, because there is no improvement over download()
	}

}

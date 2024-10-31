using System;
using System.IO;
using System.Net.Http;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using SharpCompress.Archives;
using SharpCompress.Common;

class Program
{
    private static readonly string RepoOwner = "Flowseal";
    private static readonly string RepoName = "zapret-discord-youtube";
    private static readonly string AppDirectory = AppDomain.CurrentDomain.BaseDirectory;

    /// <summary>
    /// Главный метод, запускающий процесс обновления.
    /// </summary>
    static async Task Main()
    {
        Console.WriteLine("Начинается загрузка и установка последней версии...");
        await DownloadAndInstallLatestUpdate();
    }

    /// <summary>
    /// Скачивает и устанавливает последнее обновление, создавая резервные копии текущих файлов и заменяя их новыми.
    /// </summary>
    private static async Task DownloadAndInstallLatestUpdate()
    {
        string apiUrl = $"https://api.github.com/repos/{RepoOwner}/{RepoName}/releases/latest";
        using HttpClient client = new HttpClient();
        client.DefaultRequestHeaders.UserAgent.ParseAdd("request");

        string json = await client.GetStringAsync(apiUrl);
        JObject release = JObject.Parse(json);

        // Поиск URL архива для загрузки последней версии
        string downloadUrl = release["assets"]?
            .First(asset => asset["name"].ToString().Contains("zapret-discord-youtube"))
            .Value<string>("browser_download_url");

        if (downloadUrl == null)
        {
            Console.WriteLine("Не удалось найти подходящий архив для загрузки.");
            return;
        }

        string tempFilePath = Path.Combine(AppDirectory, "update.rar");
        if (File.Exists(tempFilePath))
        {
            File.Delete(tempFilePath);
        }

        using (var response = await client.GetAsync(downloadUrl))
        {
            response.EnsureSuccessStatusCode();
            await using (var fs = new FileStream(tempFilePath, FileMode.CreateNew))
            {
                await response.Content.CopyToAsync(fs);
            }
        }

        // Создание резервной копии текущих файлов
        string backupDirectory = Path.Combine(AppDirectory, "backup");
        Directory.CreateDirectory(backupDirectory);
        foreach (var file in Directory.GetFiles(AppDirectory))
        {
            string fileName = Path.GetFileName(file);
            File.Copy(file, Path.Combine(backupDirectory, fileName), overwrite: true);
        }

        // Извлечение содержимого RAR архива и замена текущих файлов
        try
        {
            using (var archive = ArchiveFactory.Open(tempFilePath))
            {
                foreach (var entry in archive.Entries)
                {
                    if (!entry.IsDirectory)
                    {
                        entry.WriteToDirectory(AppDirectory, new ExtractionOptions() { ExtractFullPath = true, Overwrite = true });
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine($"Ошибка извлечения файла: {ex.Message}");
        }
        finally
        {
            if (File.Exists(tempFilePath))
            {
                File.Delete(tempFilePath);
            }
        }

        Console.WriteLine("Обновление завершено. Перезапустите приложение.");
    }
}

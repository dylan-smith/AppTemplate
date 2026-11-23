#:package Microsoft.Data.SqlClient@6.*

// Creates the production database users for the deploy identity (db_owner, for migrations and backups) and the App
// Service's own identity (db_datareader and db_datawriter). Safe to run again: it only adds what's missing.
//
// Run by New-App.ps1 as: dotnet run create-db-users.cs -- <server> <database> <deploy identity> <app service name>
// with SQL_ACCESS_TOKEN set to a token for the SQL server's Entra admin
// (az account get-access-token --resource https://database.windows.net/).

using Microsoft.Data.SqlClient;

if (args.Length != 4)
{
    Console.Error.WriteLine("Usage: create-db-users.cs <server> <database> <deploy identity> <app service name>");
    return 1;
}

var token = Environment.GetEnvironmentVariable("SQL_ACCESS_TOKEN");
if (string.IsNullOrEmpty(token))
{
    Console.Error.WriteLine("SQL_ACCESS_TOKEN must be set.");
    return 1;
}

var connectionString = new SqlConnectionStringBuilder
{
    DataSource = $"tcp:{args[0]},1433",
    InitialCatalog = args[1],
    Encrypt = true,
    ConnectTimeout = 60,
}.ConnectionString;

(string Name, string[] Roles)[] users =
[
    (args[2], ["db_owner"]),
    (args[3], ["db_datareader", "db_datawriter"]),
];

// A firewall rule added moments ago can take up to five minutes to apply (error 40615 until then).
for (var attempt = 1; ; attempt++)
{
    try
    {
        await using var connection = new SqlConnection(connectionString) { AccessToken = token };
        await connection.OpenAsync();

        foreach (var (name, roles) in users)
        {
            // Names can't be parameters in CREATE USER and ALTER ROLE, so QUOTENAME builds the statements.
            await using var command = connection.CreateCommand();
            command.CommandText = """
                DECLARE @sql nvarchar(max);
                IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @name)
                BEGIN
                    SET @sql = N'CREATE USER ' + QUOTENAME(@name) + N' FROM EXTERNAL PROVIDER;';
                    EXEC sys.sp_executesql @sql;
                END;
                IF IS_ROLEMEMBER(@role, @name) = 0
                BEGIN
                    SET @sql = N'ALTER ROLE ' + QUOTENAME(@role) + N' ADD MEMBER ' + QUOTENAME(@name) + N';';
                    EXEC sys.sp_executesql @sql;
                END;
                """;
            var nameParameter = command.Parameters.Add("@name", System.Data.SqlDbType.NVarChar, 128);
            var roleParameter = command.Parameters.Add("@role", System.Data.SqlDbType.NVarChar, 128);
            nameParameter.Value = name;

            foreach (var role in roles)
            {
                roleParameter.Value = role;
                await command.ExecuteNonQueryAsync();
                Console.WriteLine($"  {name}: {role}");
            }
        }

        return 0;
    }
    catch (SqlException exception) when (exception.Number == 40615 && attempt < 30)
    {
        Console.WriteLine($"  The firewall rule isn't applied yet (attempt {attempt} of 30); retrying in 10 seconds");
        await Task.Delay(TimeSpan.FromSeconds(10));
    }
}
